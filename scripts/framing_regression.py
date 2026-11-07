"""Round-trip a default-sized source event through real JSONL CLI processes."""
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import closing

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "_build/native/debug/build/cmd/main/main.exe"
EVENT_BUDGET = 16 * 1024 * 1024


def invoke(*args):
    result = subprocess.run(
        [str(EXE), *map(str, args)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=30,
    )
    if result.returncode:
        raise AssertionError(f"MoonCDC {args!r} failed: {result.stderr}")
    # --output FILE writes no JSON result to stdout.
    return json.loads(result.stdout) if result.stdout.strip() else None


def compact_json(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def main():
    template = {
        "sequence": "1",
        "table": "items",
        "operation": "insert",
        "before": None,
        "after": [["integer", "1"], ["blob", ""]],
    }
    overhead = len(compact_json(template))
    payload_size = (EVENT_BUDGET - overhead) // 2
    with tempfile.TemporaryDirectory(prefix="mooncdc-framing-") as directory:
        work = pathlib.Path(directory)
        source, target, batch_file = work / "source.db", work / "target.db", work / "batch.jsonl"
        with closing(sqlite3.connect(source, timeout=5)) as writer:
            writer.execute("PRAGMA recursive_triggers=ON")
            writer.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value BLOB)")
            writer.commit()
            invoke("install", source, "items")
            invoke("bootstrap", source, target, "offline")
            writer.execute("INSERT INTO items VALUES(1,?)", (b"a" * payload_size,))
            writer.commit()
            invoke("export", source, "offline", "--format", "jsonl", "--output", batch_file)
            with batch_file.open(encoding="utf-8") as stream:
                records = [json.loads(line) for line in stream]
            assert len(records) == 3
            event = records[1]["event"]
            event_units = len(compact_json(event))
            framed_units = len(compact_json(records[1]))
            # The event is ASCII JSON, so Python lengths equal UTF-16 units.
            assert 0 <= EVENT_BUDGET - event_units <= 1, event_units
            assert framed_units > EVENT_BUDGET, framed_units
            assert writer.execute("SELECT sequence FROM _mooncdc_consumers WHERE name='offline'").fetchone() == (0,)
            applied = invoke("apply", target, "--format", "jsonl", "--input", batch_file)
            assert applied["applied"] == 1, applied
            invoke("ack", source, "offline", "--format", "jsonl", "--input", batch_file)
            assert writer.execute("SELECT sequence FROM _mooncdc_consumers WHERE name='offline'").fetchone() == (1,)
            assert invoke("apply", target, "--format", "jsonl", "--input", batch_file)["applied"] == 0
            with closing(sqlite3.connect(target, timeout=5)) as check:
                value = check.execute("SELECT value FROM items WHERE id=1").fetchone()[0]
                assert len(value) == payload_size
                assert value == b"a" * payload_size
                assert check.execute("SELECT sequence FROM _mooncdc_projection").fetchone() == (1,)
            assert invoke("audit", source, target)["consistent"]
        print("PASS: maximum default source event exports, applies, acknowledges and replays with JSONL framing overhead")


if __name__ == "__main__":
    main()
