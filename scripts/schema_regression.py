"""External SQLite checks for unsupported update cycles and diagnostic accuracy."""
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import closing

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "_build/native/debug/build/cmd/main/main.exe"


def run(*args, succeeds=True):
    result = subprocess.run([str(EXE), *map(str, args)], capture_output=True,
                            text=True, encoding="utf-8", timeout=30)
    assert (result.returncode == 0) == succeeds, (args, result.returncode, result.stderr)
    if not succeeds:
        return result.stderr
    return json.loads(result.stdout) if result.stdout.strip() else None


def cycle_cases(directory):
    for action in ("CASCADE", "SET NULL", "SET DEFAULT"):
        source = directory / f"self-{action.replace(' ', '-')}.db"
        with closing(sqlite3.connect(source)) as db, db:
            db.execute(f"CREATE TABLE nodes(id INTEGER PRIMARY KEY,parent INTEGER DEFAULT 1 REFERENCES nodes(id) ON UPDATE {action})")
            db.execute("INSERT INTO nodes VALUES(1,1)")
        assert not run("plan", source, "nodes")["eligible"]
        run("install", source, "nodes", succeeds=False)
        with closing(sqlite3.connect(source)) as db:
            assert not db.execute("SELECT name FROM sqlite_schema WHERE name GLOB '_mooncdc_*'").fetchall()
            assert db.execute("SELECT * FROM nodes").fetchall() == [(1, 1)]

    # The second relation appears after installation, without changing the
    # captured table's original CREATE TABLE statement.
    source = directory / "late-cycle.db"
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("CREATE TABLE a(id INTEGER PRIMARY KEY,b INTEGER REFERENCES b(id) ON UPDATE CASCADE)")
    run("install", source, "a")
    snapshot = directory / "late-cycle-snapshot.json"
    run("snapshot", source, "replica", "--output", snapshot)
    with closing(sqlite3.connect(source)) as db, db:
        before = db.execute("SELECT * FROM _mooncdc_meta").fetchall()
        db.execute("CREATE TABLE b(id INTEGER PRIMARY KEY REFERENCES a(id) ON UPDATE CASCADE)")
    run("verify", source, succeeds=False)
    assert not run("diagnose", source)["healthy"]
    run("snapshot", source, "must-not-register", "--output", directory / "rejected.json", succeeds=False)
    with closing(sqlite3.connect(source)) as db:
        assert db.execute("SELECT * FROM _mooncdc_meta").fetchall() == before
        assert db.execute("SELECT name,sequence FROM _mooncdc_consumers").fetchall() == [("replica", 0)]
        assert db.execute("SELECT count(*) FROM _mooncdc_events").fetchone() == (0,)


def acyclic_case(directory):
    source, target = [directory / name for name in ("acyclic.db", "acyclic-target.db")]
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("CREATE TABLE parents(id INTEGER PRIMARY KEY)")
        db.execute("CREATE TABLE children(id INTEGER PRIMARY KEY,parent INTEGER REFERENCES parents(id) ON UPDATE CASCADE ON DELETE SET NULL)")
        db.execute("INSERT INTO parents VALUES(1)")
        db.execute("INSERT INTO children VALUES(10,1)")
    run("install", source, "parents", "children")
    run("bootstrap", source, target, "replica")
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA recursive_triggers=ON")
        db.execute("UPDATE parents SET id=2 WHERE id=1")
    run("sync", source, target, "replica", "--limit", "1")
    assert run("audit", source, target)["consistent"]
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA recursive_triggers=ON")
        db.execute("DELETE FROM parents")
    run("sync", source, target, "replica", "--limit", "1")
    assert run("audit", source, target)["consistent"]
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("CREATE TRIGGER business AFTER UPDATE ON children BEGIN SELECT 1; END")
    run("verify", source, succeeds=False)
    report = run("diagnose", source)
    assert not report["healthy"]
    assert any(issue.get("name") == "business" for issue in report["issues"])


def delete_key_cases(directory):
    source = directory / "delete-self-key.db"
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("CREATE TABLE nodes(id INTEGER PRIMARY KEY DEFAULT 1 REFERENCES nodes(refkey) ON DELETE SET DEFAULT,refkey INTEGER UNIQUE)")
        db.execute("INSERT INTO nodes VALUES(1,2),(2,1)")
    assert not run("plan", source, "nodes")["eligible"]
    assert "ON DELETE" in run("install", source, "nodes", succeeds=False)
    with closing(sqlite3.connect(source)) as db:
        assert db.execute("SELECT * FROM nodes ORDER BY id").fetchall() == [(1, 2), (2, 1)]
        assert not db.execute("SELECT name FROM sqlite_schema WHERE name GLOB '_mooncdc_*'").fetchall()

    for captured in (("a",), ("a", "b"), ("b",)):
        suffix = "-".join(captured)
        source = directory / f"delete-mixed-{suffix}.db"
        target = directory / f"delete-mixed-{suffix}-target.db"
        with closing(sqlite3.connect(source)) as db, db:
            db.execute("CREATE TABLE a(id INTEGER PRIMARY KEY DEFAULT 1 REFERENCES b(refkey) ON DELETE SET DEFAULT)")
            db.execute("CREATE TABLE b(id INTEGER PRIMARY KEY,a INTEGER REFERENCES a(id) ON UPDATE CASCADE ON DELETE CASCADE,refkey INTEGER UNIQUE)")
            db.execute("INSERT INTO a VALUES(1),(2)")
            db.execute("INSERT INTO b VALUES(1,1,2),(2,2,1)")
        plan = run("plan", source, *captured)
        if "a" in captured:
            assert not plan["eligible"]
            assert "ON DELETE" in run("install", source, *captured, succeeds=False)
        else:
            assert plan["eligible"]
            run("install", source, *captured)
            run("bootstrap", source, target, "replica")
            with closing(sqlite3.connect(source)) as db, db:
                db.execute("PRAGMA foreign_keys=ON")
                db.execute("PRAGMA recursive_triggers=ON")
                db.execute("DELETE FROM a WHERE id=1")
            run("sync", source, target, "replica", "--limit", "1")
            assert run("audit", source, target)["consistent"]


def main():
    with tempfile.TemporaryDirectory(prefix="mooncdc-schema-") as directory:
        work = pathlib.Path(directory)
        cycle_cases(work)
        acyclic_case(work)
        delete_key_cases(work)
    print(f"PASS: SQLite {sqlite3.sqlite_version}: unsafe UPDATE cycles and DELETE key-return paths rejected; acyclic cascades and safe capture subsets synchronize; added business triggers are diagnosed")


if __name__ == "__main__":
    main()
