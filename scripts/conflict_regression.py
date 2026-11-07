"""Independent partial-FAIL commits, pruning and sequence-reuse regressions."""
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import closing

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "_build/native/debug/build/cmd/main/main.exe"


def run(*args):
    result = subprocess.run([str(EXE), *map(str, args)], capture_output=True,
                            text=True, encoding="utf-8", timeout=30)
    if result.returncode:
        raise AssertionError((args, result.returncode, result.stderr))
    return json.loads(result.stdout)


def observed(path):
    with closing(sqlite3.connect(path)) as db:
        return db.execute("SELECT id,value,typeof(id),typeof(value) FROM items ORDER BY id").fetchall()


def partial_fail_case(directory, operation, prior_events, bounded):
    prefix = f"{operation}-{prior_events}-{bounded}"
    source, target = [directory / f"{prefix}-{name}.db" for name in ("source", "target")]
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT UNIQUE)")
        db.execute("INSERT INTO items VALUES(1,'one'),(2,'two')")
    run("install", source, "items")
    if prior_events:
        with closing(sqlite3.connect(source)) as db, db:
            db.execute("PRAGMA recursive_triggers=ON")
            db.execute("UPDATE items SET value='prior-'||id")
    run("bootstrap", source, target, "replica")
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("PRAGMA recursive_triggers=ON")
        try:
            if operation == "insert":
                db.execute("INSERT OR FAIL INTO items VALUES(3,'kept'),(1,'conflict')")
            else:
                db.execute("UPDATE OR FAIL items SET value='kept'")
        except sqlite3.IntegrityError:
            pass  # FAIL preserves the first change; deliberately commit it.
        else:
            raise AssertionError("Expected a partial FAIL conflict")
        actual_sequence = db.execute("SELECT max(sequence) FROM _mooncdc_events").fetchone()[0]
        assert actual_sequence == prior_events + 1, (prefix, actual_sequence)
    cursor = prior_events + 1
    status = run("status", source)
    assert int(status["cursor"]["sequence"]) == cursor, (prefix, status)
    assert status["journal_contiguous"]
    assert run("sync", source, target, "replica")["applied"] == 1
    assert observed(source) == observed(target)
    assert run("audit", source, target)["consistent"]
    if bounded:
        for _ in range(cursor):
            assert int(run("prune-bounded", source, "--limit", "1")["deleted"]) == 1
    else:
        assert int(run("prune", source)["deleted"]) == cursor
    with closing(sqlite3.connect(source)) as db, db:
        assert db.execute("SELECT count(*) FROM _mooncdc_events").fetchone() == (0,)
        assert db.execute("SELECT seq FROM sqlite_sequence WHERE name='_mooncdc_events'").fetchone()[0] >= cursor
        db.execute("PRAGMA recursive_triggers=ON")
        db.execute("INSERT INTO items VALUES(10,'after-pruning')")
        assert db.execute("SELECT sequence FROM _mooncdc_events").fetchone() == (cursor + 1,)
    assert run("sync", source, target, "replica")["applied"] == 1
    assert observed(source) == observed(target)
    assert run("audit", source, target)["consistent"]
    assert run("verify", source)["valid"]


def trusted_schema_case(directory):
    source = directory / "trusted-schema.db"
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)")
        db.execute("INSERT INTO items VALUES(1,'unchanged')")
    run("install", source, "items")
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("PRAGMA recursive_triggers=ON")
        db.execute("PRAGMA trusted_schema=OFF")
        try:
            db.execute("UPDATE items SET value='must-not-commit'")
        except sqlite3.DatabaseError as error:
            assert "unsafe use" in str(error), str(error)
        else:
            raise AssertionError("Capture requires trusted_schema=ON on its writer")
        assert db.execute("SELECT value FROM items").fetchone() == ("unchanged",)
        assert db.execute("SELECT count(*) FROM _mooncdc_events").fetchone() == (0,)
        db.execute("PRAGMA trusted_schema=ON")
        db.execute("UPDATE items SET value='captured'")
    assert run("verify", source)["checked"] == 1


def main():
    with tempfile.TemporaryDirectory(prefix="mooncdc-conflict-") as directory:
        work = pathlib.Path(directory)
        for operation in ("insert", "update"):
            for prior_events in (0, 2):
                for bounded in (False, True):
                    partial_fail_case(work, operation, prior_events, bounded)
        trusted_schema_case(work)
    print(f"PASS: SQLite {sqlite3.sqlite_version}: 8 partial-FAIL commit/prune/restart cases preserve rows, types and monotonic cursors; trusted_schema restriction fails without partial changes")


if __name__ == "__main__":
    main()
