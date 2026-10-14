"""Create disposable databases, capture an external write, then synchronize and audit."""
import json
import pathlib
import sqlite3
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cmd/main/main.exe"


def run(*args):
    result = subprocess.run([str(EXE), *map(str, args)], check=True, capture_output=True, text=True, encoding="utf-8")
    return json.loads(result.stdout)


with tempfile.TemporaryDirectory(prefix="mooncdc-demo-") as directory:
    source = pathlib.Path(directory) / "source.db"
    target = pathlib.Path(directory) / "report.db"
    db = sqlite3.connect(source)
    try:
        db.execute("PRAGMA recursive_triggers=ON")
        db.execute("CREATE TABLE orders(id INTEGER PRIMARY KEY,status TEXT,amount INTEGER)")
        db.execute("INSERT INTO orders VALUES(1,'pending',200)")
        db.commit()
        print("install", run("install", source, "orders"))
        print("bootstrap", run("bootstrap", source, target, "reporting"))
        db.execute("UPDATE orders SET status='paid' WHERE id=1")
        db.execute("INSERT INTO orders VALUES(2,'paid',300)")
        db.commit()
        print("sync", run("sync", source, target, "reporting"))
        print("audit", run("audit", source, target))
    finally:
        db.close()
