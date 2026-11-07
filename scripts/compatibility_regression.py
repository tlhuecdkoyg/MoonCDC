"""Check 128-column capture with an external SQLite function-argument cap of 127.

The cap reproduces the default before SQLite 3.48.0 even on newer Python builds.
Also exercise quoted/Unicode identifiers and extreme typed values.
"""
import json
import pathlib
import sqlite3
import subprocess
import tempfile
from contextlib import closing

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cmd/main/main.exe"


def run(*args):
    result = subprocess.run([str(EXE), *map(str, args)], capture_output=True,
                            text=True, encoding="utf-8", timeout=60)
    if result.returncode:
        raise AssertionError((args, result.returncode, result.stderr))
    return json.loads(result.stdout) if result.stdout.strip() else None


def quote(name):
    return '"' + name.replace('"', '""') + '"'


def pragma_collision(directory):
    source, target = [directory / name for name in ("pragma-source.db", "pragma-target.db")]
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT UNIQUE)")
        db.execute("INSERT INTO items VALUES(1,'unique')")
    run("install", source, "items")
    run("bootstrap", source, target, "pragma")
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("CREATE TABLE pragma_recursive_triggers(recursive_triggers)")
        db.execute("INSERT INTO pragma_recursive_triggers VALUES(1)")
        db.execute("PRAGMA recursive_triggers=OFF")
        try:
            db.execute("INSERT OR REPLACE INTO items VALUES(2,'unique')")
        except sqlite3.DatabaseError as error:
            assert "not a function" in str(error), str(error)
        else:
            raise AssertionError("An ordinary table spoofed the recursive_triggers guard")
        assert db.execute("SELECT * FROM items").fetchall() == [(1, "unique")]
        assert db.execute("SELECT count(*) FROM _mooncdc_events").fetchone() == (0,)
        db.execute("DROP TABLE pragma_recursive_triggers")
        db.execute("PRAGMA recursive_triggers=ON")
        db.execute("INSERT OR REPLACE INTO items VALUES(2,'unique')")
    assert run("sync", source, target, "pragma")["applied"] == 2
    assert run("audit", source, target)["consistent"]
    print("PASS: ordinary tables cannot spoof the recursive_triggers guard; rejected REPLACE leaves no partial row or event")


def main():
    with tempfile.TemporaryDirectory(prefix="mooncdc-capacity-") as directory:
        source, target = [pathlib.Path(directory) / name for name in ("source.db", "target.db")]
        names = ["normal", 'odd"; DROP TABLE normal;--', "含空格 😀", "\ufeffstart", "new", "old"]
        with closing(sqlite3.connect(source)) as db, db:
            db.setlimit(sqlite3.SQLITE_LIMIT_FUNCTION_ARG, 127)
            for name in names:
                db.execute(f"CREATE TABLE {quote(name)}(id INTEGER PRIMARY KEY,value,note)")
                db.execute(f"INSERT INTO {quote(name)} VALUES(?,?,?)", (-(2**63), "\ufeffbefore\0😀", b"\x00\xff"))
            columns = [f'"c{index}"' for index in range(128)]
            db.execute("CREATE TABLE wide(" + ",".join(columns) + ",PRIMARY KEY(c0))")
            db.execute("INSERT INTO wide VALUES(" + ",".join("?" for _ in columns) + ")",
                       tuple([1] + [1e300, -1e-300, b"\0\xff", "\ufefftext\0😀", None, 2**63-1, -(2**63)] * 18 + ["last"]))
        run("install", source, *names, "wide")
        run("bootstrap", source, target, "capacity")
        with closing(sqlite3.connect(source)) as db, db:
            db.setlimit(sqlite3.SQLITE_LIMIT_FUNCTION_ARG, 127)
            db.execute("PRAGMA recursive_triggers=ON")
            for name in names:
                db.execute(f"UPDATE {quote(name)} SET id=?,value=?,note=?", (2**63-1, "\ufeffafter\0😀", b"\xff\x00"))
            db.execute("UPDATE wide SET c1=?,c3=?,c4=?", (-1e300, b"", "\ufeffafter\0😀"))
            db.execute("INSERT INTO wide SELECT 2," + ",".join(f'c{i}' for i in range(1, 128)) + " FROM wide WHERE c0=1")
        run("sync", source, target, "capacity", "--limit", "1")
        assert run("audit", source, target)["consistent"]
        with closing(sqlite3.connect(source)) as left, closing(sqlite3.connect(target)) as right:
            for name in names + ["wide"]:
                assert left.execute(f"SELECT * FROM {quote(name)}").fetchall() == right.execute(f"SELECT * FROM {quote(name)}").fetchall(), name
        with closing(sqlite3.connect(source)) as db, db:
            db.setlimit(sqlite3.SQLITE_LIMIT_FUNCTION_ARG, 127)
            db.execute("PRAGMA recursive_triggers=ON")
            db.execute("DELETE FROM wide WHERE c0=1")
        run("sync", source, target, "capacity", "--limit", "1")
        assert run("audit", source, target)["consistent"]
        print(f"PASS: SQLite {sqlite3.sqlite_version} at function-argument cap 127, 128-column CDC and extreme Int64/quoted/BOM/Unicode identifiers")
        pragma_collision(pathlib.Path(directory))


if __name__ == "__main__":
    main()
