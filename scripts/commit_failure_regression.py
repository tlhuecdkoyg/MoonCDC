"""Hold a real target reader lock through COMMIT, then verify atomic recovery."""
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import closing

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "_build/native/debug/build/cmd/main/main.exe"


def invoke(*args, success=True):
    result = subprocess.run(
        [str(EXE), *map(str, args)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=20,
    )
    if success and result.returncode:
        raise AssertionError(f"MoonCDC {args!r} failed: {result.stderr}")
    if not success:
        assert result.returncode != 0, (args, result.stdout)
    return result


def main():
    with tempfile.TemporaryDirectory(prefix="mooncdc-commit-failure-") as directory:
        work = pathlib.Path(directory)
        source, target = work / "source.db", work / "target.db"
        with closing(sqlite3.connect(source, timeout=5)) as writer:
            writer.execute("PRAGMA recursive_triggers=ON")
            writer.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)")
            writer.commit()
            invoke("install", source, "items")
            initialized = json.loads(invoke("bootstrap", source, target, "reporting").stdout)
            initial_cursor = initialized["cursor"]
            assert initial_cursor["sequence"] == "0"
            with closing(sqlite3.connect(target, timeout=1)) as reader:
                # A SHARED reader allows BEGIN IMMEDIATE and row changes, but
                # blocks the writer's final EXCLUSIVE lock in rollback mode.
                mode = reader.execute("PRAGMA journal_mode=DELETE").fetchone()[0]
                assert mode.lower() == "delete", mode
                reader.execute("BEGIN")
                assert reader.execute("SELECT * FROM items").fetchall() == []
                try:
                    writer.execute("INSERT INTO items VALUES(1,'one'),(2,'two')")
                    writer.commit()
                    failed = invoke("sync", source, target, "reporting", success=False)
                    assert "database is locked" in failed.stderr.lower(), failed.stderr
                    with closing(sqlite3.connect(target, timeout=1)) as check:
                        assert check.execute("SELECT * FROM items").fetchall() == []
                        assert check.execute("SELECT source_id,sequence FROM _mooncdc_projection").fetchone() == (initial_cursor["source"], 0)
                    assert writer.execute("SELECT sequence FROM _mooncdc_consumers WHERE name='reporting'").fetchone() == (0,)
                    assert writer.execute("SELECT count(*) FROM _mooncdc_events").fetchone() == (2,)
                finally:
                    reader.rollback()
            # Retry in a fresh CLI process after releasing the reader. Neither
            # partial target writes nor an advanced source ack may survive.
            recovered = json.loads(invoke("sync", source, target, "reporting").stdout)
            assert recovered["applied"] == 2, recovered
            assert recovered["cursor"] == recovered["source"], recovered
            assert recovered["cursor"]["sequence"] == "2"
            assert writer.execute("SELECT sequence FROM _mooncdc_consumers WHERE name='reporting'").fetchone() == (2,)
            with closing(sqlite3.connect(target, timeout=1)) as check:
                assert check.execute("SELECT id,value FROM items ORDER BY id").fetchall() == [(1, "one"), (2, "two")]
                assert check.execute("SELECT source_id,sequence FROM _mooncdc_projection").fetchone() == (initial_cursor["source"], 2)
            assert json.loads(invoke("audit", source, target).stdout)["consistent"]
            assert json.loads(invoke("sync", source, target, "reporting").stdout)["applied"] == 0
        print("PASS: target COMMIT busy rolls back data/cursor, preserves source ack, and retries without duplicates")


if __name__ == "__main__":
    main()
