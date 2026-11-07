"""Terminate real sync processes at two durable transaction boundaries."""
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import time
from contextlib import closing

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "_build/native/debug/build/cmd/main/main.exe"
ROWS = 700
BATCH = 50


def run(*args):
    p = subprocess.run([str(EXE), *map(str, args)], capture_output=True,
                       text=True, encoding="utf-8", timeout=30)
    assert p.returncode == 0, (args, p.stderr)
    return json.loads(p.stdout)


def clone(source, destination):
    with closing(sqlite3.connect(source)) as src, closing(sqlite3.connect(destination)) as dst:
        src.backup(dst)


def cursor(path):
    with closing(sqlite3.connect(path, timeout=0.1)) as db:
        return db.execute("SELECT sequence FROM _mooncdc_projection").fetchone()[0]


def commit_pending(path, table):
    # Our SHARED blocker does not block another reader. BUSY here proves the
    # writer has reached PENDING while waiting for the EXCLUSIVE commit lock.
    try:
        with closing(sqlite3.connect(path, timeout=0)) as probe:
            probe.execute(f"SELECT * FROM {table} LIMIT 1").fetchone()
        return False
    except sqlite3.OperationalError as error:
        if error.sqlite_errorcode == sqlite3.SQLITE_BUSY:
            return True
        raise


def verify_prefix(source, target, expected):
    with closing(sqlite3.connect(target)) as db:
        position = db.execute("SELECT sequence FROM _mooncdc_projection").fetchone()[0]
        assert position == expected, (position, expected)
        rows = db.execute("SELECT id,value FROM items ORDER BY id").fetchall()
        assert rows == [(i, "after" if i < position else "before") for i in range(ROWS)]
    with closing(sqlite3.connect(source)) as db:
        ack = db.execute("SELECT sequence FROM _mooncdc_consumers WHERE name='replica'").fetchone()[0]
        assert ack == 0, ack
    run("sync", source, target, "replica", "--limit", "73", "--max-batches", "100")
    assert run("audit", source, target)["consistent"]
    assert cursor(target) == ROWS
    with closing(sqlite3.connect(source)) as db:
        assert db.execute("SELECT sequence FROM _mooncdc_consumers WHERE name='replica'").fetchone()[0] == ROWS


def exercise(work, base_source, base_target, phase):
    source, target = work / f"{phase}-source.db", work / f"{phase}-target.db"
    clone(base_source, source)
    clone(base_target, target)
    locked = target if phase == "before-target-commit" else source
    table = "items" if phase == "before-target-commit" else "_mooncdc_consumers"
    process = None
    with closing(sqlite3.connect(locked, timeout=1)) as blocker:
        assert blocker.execute("PRAGMA journal_mode=DELETE").fetchone()[0].lower() == "delete"
        blocker.execute("BEGIN")
        blocker.execute(f"SELECT * FROM {table}").fetchall()
        try:
            process = subprocess.Popen([str(EXE), "sync", str(source), str(target), "replica",
                                        "--limit", str(BATCH), "--max-batches", "100"],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, encoding="utf-8")
            journal = pathlib.Path(str(locked) + "-journal")
            deadline = time.monotonic() + 20
            reached = False
            while time.monotonic() < deadline and process.poll() is None:
                try:
                    journal_written = journal.stat().st_size > 0
                except FileNotFoundError:
                    journal_written = False
                if journal_written and commit_pending(locked, table):
                    if phase == "before-target-commit" or cursor(target) == BATCH:
                        reached = True
                        break
                time.sleep(0.005)
            if not reached:
                if process.poll() is None:
                    process.kill()
                _, stderr = process.communicate(timeout=5)
                raise AssertionError((phase, process.returncode, stderr))
            process.kill()
            process.communicate(timeout=5)
            assert process.returncode != 0
        finally:
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=5)
            blocker.rollback()
    expected = 0 if phase == "before-target-commit" else BATCH
    verify_prefix(source, target, expected)
    print(f"PASS: real process kill {phase}; durable target={expected}, source ack=0; restart converges to {ROWS}")


def main():
    with tempfile.TemporaryDirectory(prefix="mooncdc-kill-review-") as directory:
        work = pathlib.Path(directory)
        source, target = work / "base-source.db", work / "base-target.db"
        with closing(sqlite3.connect(source)) as db, db:
            db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)")
            db.executemany("INSERT INTO items VALUES(?,'before')", [(i,) for i in range(ROWS)])
        run("install", source, "items")
        run("bootstrap", source, target, "replica")
        with closing(sqlite3.connect(source)) as db, db:
            db.execute("PRAGMA recursive_triggers=ON")
            # Explicit statement order makes the expected first-batch prefix
            # independent of SQLite's row visitation strategy for bulk UPDATE.
            db.executemany("UPDATE items SET value='after' WHERE id=?", [(i,) for i in range(ROWS)])
        for phase in ("before-target-commit", "after-target-before-ack"):
            exercise(work, source, target, phase)


if __name__ == "__main__":
    main()
