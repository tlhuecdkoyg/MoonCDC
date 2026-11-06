"""Independent binary64 preservation tests using Python SQLite and struct.

Run after `moon build --target native`; optionally pass the native executable.
Assertions compare source/target storage classes and all 64 REAL bits, without
reusing MoonCDC's JSON parser, equality implementation, or REAL wire decoder.
"""
import json
import math
import pathlib
import random
import sqlite3
import struct
import subprocess
import sys
import tempfile
from contextlib import contextmanager

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "_build/native/debug/build/cmd/main/main.exe"


def run(*args):
    result = subprocess.run(
        [str(EXE), *map(str, args)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=60,
    )
    if result.returncode:
        raise AssertionError(f"MoonCDC {args!r} failed: {result.stderr}")
    return json.loads(result.stdout) if result.stdout.strip() else None


@contextmanager
def database(path):
    connection = sqlite3.connect(path)
    try:
        connection.execute("PRAGMA recursive_triggers=ON")
        with connection:
            yield connection
    finally:
        connection.close()


def from_bits(bits):
    return struct.unpack(">d", bits.to_bytes(8, "big"))[0]


def observed_rows(path):
    with database(path) as connection:
        rows = connection.execute("SELECT id,value,typeof(value),note FROM samples ORDER BY id").fetchall()
    return [
        (key, struct.pack(">d", value).hex(), kind, note)
        for key, value, kind, note in rows
    ]


def assert_identical(source, target, phase):
    expected, actual = observed_rows(source), observed_rows(target)
    assert len(expected) == len(actual), (phase, "row count", len(expected), len(actual))
    for left, right in zip(expected, actual):
        assert left == right, (phase, "binary64/storage mismatch", left, right)


def finite_values():
    values = [
        1e300,
        -1e300,
        1e299,
        -1e299,
        1e-300,
        -1e-300,
        0.0,
        -0.0,
        from_bits(1),
        from_bits(0x8000000000000001),
        from_bits(0x000FFFFFFFFFFFFF),
        from_bits(0x0010000000000000),
        from_bits(0x0010000000000001),
        from_bits(0x3FEFFFFFFFFFFFFF),
        from_bits(0x3FF0000000000001),
        from_bits(0x7FEFFFFFFFFFFFFF),
        from_bits(0xFFEFFFFFFFFFFFFF),
    ]
    # Sweep the finite exponent range with varying low significand bits.
    for exponent in range(0x7FF):
        bits = exponent << 52 | (exponent * 0x179ABCD123) & 0x000FFFFFFFFFFFFF
        values.append(from_bits(bits))
        values.append(from_bits(bits | 0x8000000000000000))
    rng = random.Random(20261106)
    for _ in range(1024):
        value = from_bits(rng.getrandbits(64))
        if math.isfinite(value):
            values.append(value)
    return values


def main():
    with tempfile.TemporaryDirectory(prefix="mooncdc-real-") as directory:
        work = pathlib.Path(directory)
        source = work / "source.db"
        with database(source) as connection:
            connection.execute("CREATE TABLE samples(id INTEGER PRIMARY KEY,value REAL,note TEXT)")
            connection.executemany(
                "INSERT INTO samples VALUES(?,?,?)",
                [(1, 1e300, "initial"), (2, -1e300, "initial")],
            )
        run("install", source, "samples")
        targets = []
        for mode in ("direct", "json", "jsonl"):
            target = work / f"{mode}.db"
            if mode == "direct":
                run("bootstrap", source, target, mode)
            else:
                snapshot = work / f"snapshot.{mode}"
                run("snapshot", source, mode, "--format", mode, "--output", snapshot)
                run("init", target, "--format", mode, "--input", snapshot)
            assert_identical(source, target, f"{mode}: initial 1e300 snapshot")
            targets.append((mode, target))
        # Unchanged large before-images must survive ordinary non-REAL updates.
        with database(source) as connection:
            connection.execute("UPDATE samples SET note='ordinary update'")
        for mode, target in targets:
            assert run("sync", source, target, mode)["applied"] == 2
            assert_identical(source, target, f"{mode}: unchanged REAL before-image")
        values = finite_values()
        with database(source) as connection:
            connection.execute("UPDATE samples SET value=? WHERE id=1", (1e299,))
            connection.execute("UPDATE samples SET value=? WHERE id=2", (-1e299,))
            connection.executemany(
                "INSERT INTO samples VALUES(?,?,?)",
                [(key + 3, value, "boundary sweep") for key, value in enumerate(values)],
            )
        for mode, target in targets:
            wire_format = "jsonl" if mode == "jsonl" else "json"
            batch = work / f"batch-{mode}.{wire_format}"
            run("export", source, mode, "--limit", "100000", "--format", wire_format, "--output", batch)
            assert run("preview", target, "--format", wire_format, "--input", batch)["applicable"]
            result = run("apply", target, "--format", wire_format, "--input", batch)
            assert result["applied"] == len(values) + 2, result
            assert_identical(source, target, f"{mode}: REAL exponent sweep")
            assert run("apply", target, "--format", wire_format, "--input", batch)["applied"] == 0
            assert run("sync", source, target, mode)["applied"] == 0
        for cycle in range(3):
            with database(source) as connection:
                connection.execute("UPDATE samples SET value=-value,note=?", (f"cycle-{cycle}",))
            for mode, target in targets:
                result = run("sync", source, target, mode, "--limit", "127", "--max-batches", "1000")
                assert result["applied"] == len(values) + 2, result
                assert_identical(source, target, f"{mode}: continued update {cycle}")
        with database(source) as connection:
            connection.execute("DELETE FROM samples WHERE id%3=0")
        for mode, target in targets:
            run("sync", source, target, mode, "--max-batches", "1000")
            assert_identical(source, target, f"{mode}: delete before-images")
            assert run("audit", source, target)["consistent"]
        print(
            f"PASS: {len(values)} finite REAL samples; all exponents, subnormals, extremes, "
            "direct/JSON/JSONL snapshots and batches, repeated updates, replay and delete; "
            "independent Python struct bit comparisons"
        )


if __name__ == "__main__":
    main()
