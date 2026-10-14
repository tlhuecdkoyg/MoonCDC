"""Real CLI processes against databases written by Python's SQLite driver."""
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import random
from contextlib import contextmanager

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "_build/native/debug/build/cmd/main/main.exe"


def run(*args, ok=True):
    result = subprocess.run([str(EXE), *map(str, args)], capture_output=True, text=True, encoding="utf-8", timeout=30)
    if ok and result.returncode:
        raise AssertionError(f"{args}: {result.stderr}")
    if not ok:
        assert result.returncode != 0, args
        return result.stderr
    return result.stdout


@contextmanager
def connect(path):
    db = sqlite3.connect(path)
    try:
        db.execute("PRAGMA recursive_triggers=ON")
        with db:
            yield db
    finally:
        db.close()


def main():
    with tempfile.TemporaryDirectory(prefix="mooncdc-") as directory:
        work = pathlib.Path(directory)
        source, target = work / "source.db", work / "target.db"
        with connect(source) as db:
            db.execute('CREATE TABLE records(id INTEGER PRIMARY KEY,value,payload BLOB)')
            db.execute('INSERT INTO records VALUES(?,?,?)', (9223372036854775807, "初始\x00文本", b"\x00\xff"))
        assert json.loads(run("plan", source, "records"))["eligible"]
        run("install", source, "records")
        run("bootstrap", source, target, "replica")
        with connect(source) as db:
            db.execute("UPDATE records SET value=?", (0.12345678901234567,))
            db.execute("INSERT INTO records VALUES(2,'new',X'12')")
        batch = work / "batch.jsonl"
        run("export", source, "replica", "--format", "jsonl", "--output", batch)
        assert json.loads(run("apply", target, "--format", "jsonl", "--input", batch))["applied"] == 2
        # Simulate process loss after target COMMIT, before acknowledgement.
        # Every CLI call has exited; restart sync must recover from durable metadata.
        assert json.loads(run("sync", source, target, "replica"))["applied"] == 0
        assert json.loads(run("audit", source, target))["consistent"]
        assert json.loads(run("apply", target, "--format", "jsonl", "--input", batch))["applied"] == 0
        truncated = work / "truncated.jsonl"
        truncated.write_text("\n".join(batch.read_text(encoding="utf-8").splitlines()[:-1]), encoding="utf-8")
        run("apply", target, "--format", "jsonl", "--input", truncated, ok=False)
        # An actual uncommitted external transaction must roll back on process death.
        code = "import sqlite3,sys,time; d=sqlite3.connect(sys.argv[1]); d.execute('PRAGMA recursive_triggers=ON'); d.execute(\"INSERT INTO records VALUES(3,'uncommitted',NULL)\"); print('ready',flush=True); time.sleep(60)"
        writer = subprocess.Popen([sys.executable, "-c", code, str(source)], stdout=subprocess.PIPE, text=True)
        try:
            assert writer.stdout.readline().strip() == "ready"
            writer.kill()
            writer.wait(timeout=10)
        finally:
            if writer.poll() is None:
                writer.kill()
                writer.wait()
        assert json.loads(run("verify", source))["checked"] == 2
        with connect(source) as db:
            assert not db.execute("SELECT 1 FROM records WHERE id=3").fetchall()
            db.execute("DELETE FROM records WHERE id=2")
        assert json.loads(run("sync", source, target, "replica", "--limit", "1"))["applied"] == 1
        assert json.loads(run("audit", source, target))["consistent"]
        assert json.loads(run("prune", source))["deleted"] == "3"
        assert json.loads(run("verify", source))["checked"] == 0
        run("bootstrap", source, target, "must-not-register", ok=False)
        run("sync", source, source, "replica", ok=False)
        run("status", work / "missing.db", ok=False)
        assert not (work / "missing.db").exists()
        run("export", source, "replica", "--output", batch, ok=False)
        run("pause", source, "replica")
        run("sync", source, target, "replica", ok=False)
        run("resume", source, "replica")
        run("sync", source, target, "replica")
        assert json.loads(run("diagnose", source))["healthy"]
        assert json.loads(run("target-status", target))["cursor"] == json.loads(run("status", source))["cursor"]
        plan_file = work / "plan.json"
        run("make-plan", source, "--output", plan_file)
        plan = json.loads(plan_file.read_text(encoding="utf-8"))
        plan["rules"][0]["target"] = "visible"
        plan["rules"][0]["filter"] = {"op": "integer_between", "column": "id", "lower": "1", "upper": "100"}
        plan_file.write_text(json.dumps(plan), encoding="utf-8")
        filtered = work / "filtered.db"
        run("bootstrap", source, filtered, "filtered", "--plan", plan_file)
        with connect(source) as db:
            db.execute("INSERT INTO records VALUES(4,'visible',NULL)")
        pending = work / "pending.json"
        run("export", source, "filtered", "--output", pending)
        assert json.loads(run("preview", filtered, "--input", pending, "--plan", plan_file))["applicable"]
        assert json.loads(run("sync", source, filtered, "filtered", "--plan", plan_file))["applied"] == 1
        assert json.loads(run("audit", source, filtered, "--plan", plan_file))["consistent"]
        changed = work / "changed-plan.json"
        plan["rules"][0]["filter"] = {"op": "always"}
        changed.write_text(json.dumps(plan), encoding="utf-8")
        run("sync", source, filtered, "filtered", "--plan", changed, ok=False)
        run("sync", source, target, "replica")
        with connect(target) as db:
            db.execute("UPDATE records SET value='external divergence'")
        assert not json.loads(run("audit", source, target))["consistent"]
        # Concurrent commits around bootstrap must appear in snapshot or journal,
        # with neither loss nor duplicate application at the handoff.
        concurrent_source, concurrent_target = work / "concurrent.db", work / "concurrent-target.db"
        with connect(concurrent_source) as db:
            db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value)")
        run("install", concurrent_source, "items")
        writer_code = """import sqlite3,sys,time
d=sqlite3.connect(sys.argv[1], timeout=10)
d.execute('PRAGMA recursive_triggers=ON')
print('ready',flush=True)
for i in range(150):
    d.execute('INSERT INTO items VALUES(?,?)',(i,'initial'))
    d.commit()
    time.sleep(0.002)
d.close()
"""
        writer = subprocess.Popen([sys.executable, "-c", writer_code, str(concurrent_source)], stdout=subprocess.PIPE, text=True)
        try:
            assert writer.stdout.readline().strip() == "ready"
            run("bootstrap", concurrent_source, concurrent_target, "concurrent")
            assert writer.wait(timeout=20) == 0
        finally:
            if writer.poll() is None:
                writer.kill()
                writer.wait()
        run("sync", concurrent_source, concurrent_target, "concurrent", "--limit", "7")
        assert json.loads(run("audit", concurrent_source, concurrent_target))["consistent"]
        rng = random.Random(20261014)
        values = [None, -9223372036854775808, 9223372036854775807, 0.12345678901234567, "text\x00尾", b"\x00\xff"]
        for cycle in range(5):
            with connect(concurrent_source) as db:
                for _ in range(60):
                    key = rng.randrange(150)
                    if rng.randrange(4) == 0:
                        db.execute("DELETE FROM items WHERE id=?", (key,))
                    else:
                        db.execute("INSERT INTO items VALUES(?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", (key, rng.choice(values)))
            run("sync", concurrent_source, concurrent_target, "concurrent", "--limit", "11")
            assert json.loads(run("audit", concurrent_source, concurrent_target))["consistent"], cycle
        print("PASS: concurrent snapshot handoff and seeded mixed-type mutation replay")
        print("PASS: external writer, typed values, durable restart, replay, killed transaction, retention, divergence and CLI guards")


if __name__ == "__main__":
    main()
