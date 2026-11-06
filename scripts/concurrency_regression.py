"""Exercise concurrent writers, two native sync workers and safe journal pruning.

Run after `moon build --target native`, with an optional native executable path.
Only documented cursor/CAS and SQLite lock races are retried by later bounded
worker invocations. The final independent SQLite checks must match every row.
"""
import concurrent.futures
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = (
    pathlib.Path(sys.argv[1]).resolve()
    if len(sys.argv) > 1
    else ROOT / "_build/native/debug/build/cmd/main/main.exe"
)
COMMITS = 200
KEYS = 37
WORKER_ROUNDS = 24
TOTAL_TIMEOUT = 90
COMMAND_TIMEOUT = 20
RECOVERABLE = (
    "consumer cursor changed concurrently",
    "source acknowledgement is ahead of or unrelated to target",
    "batch does not start at the projection cursor",
    "cursor precedes retained history",
    "database is locked",
    "database table is locked",
    "sqlite_busy",
    "sqlite_locked",
)


def rows(path):
    connection = sqlite3.connect(path, timeout=5)
    try:
        return connection.execute(
            "SELECT id,value,typeof(id),typeof(value) FROM items ORDER BY id"
        ).fetchall()
    finally:
        connection.close()


def main():
    deadline = time.monotonic() + TOTAL_TIMEOUT
    stopped = threading.Event()
    lock = threading.Lock()
    children = set()
    races = []

    def remaining():
        budget = deadline - time.monotonic()
        if budget <= 0:
            raise AssertionError("Concurrency regression exceeded its overall timeout")
        return budget

    def stop_children():
        stopped.set()
        with lock:
            active = list(children)
        for child in active:
            if child.poll() is None:
                try:
                    child.kill()
                except ProcessLookupError:
                    pass
        # Each command's owning thread collects stdout/stderr and reaps its child.

    def command(*args):
        if stopped.is_set():
            raise AssertionError("Concurrent worker cancelled after another failure")
        timeout = min(COMMAND_TIMEOUT, remaining())
        child = subprocess.Popen(
            [str(EXE), *map(str, args)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        with lock:
            children.add(child)
        try:
            try:
                stdout, stderr = child.communicate(timeout=timeout)
            except subprocess.TimeoutExpired as error:
                child.kill()
                child.communicate()
                raise AssertionError(f"CLI command timed out: {args!r}") from error
            return subprocess.CompletedProcess(args, child.returncode, stdout, stderr)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()
            with lock:
                children.discard(child)

    def must(*args):
        result = command(*args)
        assert result.returncode == 0, (args, result.stderr)
        return json.loads(result.stdout)

    def racing_command(*args):
        result = command(*args)
        if result.returncode:
            message = result.stderr.strip()
            assert any(reason in message.lower() for reason in RECOVERABLE), (
                "Unexpected concurrent failure",
                args,
                message,
            )
            with lock:
                races.append(message)

    with tempfile.TemporaryDirectory(prefix="mooncdc-concurrency-") as directory:
        work = pathlib.Path(directory)
        source, target = work / "source.db", work / "target.db"
        connection = sqlite3.connect(source)
        try:
            connection.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value INTEGER)")
            connection.commit()
        finally:
            connection.close()
        must("install", source, "items")
        must("bootstrap", source, target, "replica")
        barrier = threading.Barrier(4, timeout=10)

        def writer():
            barrier.wait()
            connection = sqlite3.connect(source, timeout=5)
            try:
                connection.execute("PRAGMA recursive_triggers=ON")
                for value in range(COMMITS):
                    if stopped.is_set():
                        return
                    remaining()
                    connection.execute(
                        "INSERT INTO items VALUES(?,?) "
                        "ON CONFLICT(id) DO UPDATE SET value=excluded.value",
                        (value % KEYS, value),
                    )
                    connection.commit()
                    # Briefly yield so snapshot/read/apply/ack boundaries overlap writes.
                    time.sleep(0.001)
            finally:
                connection.close()

        def syncer(limit):
            barrier.wait()
            for _ in range(WORKER_ROUNDS):
                if stopped.is_set():
                    return
                racing_command(
                    "sync", source, target, "replica",
                    "--limit", limit, "--max-batches", 3,
                )

        def pruner():
            barrier.wait()
            for _ in range(WORKER_ROUNDS):
                if stopped.is_set():
                    return
                racing_command("prune-bounded", source, "--limit", 3)

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            jobs = [
                pool.submit(writer),
                pool.submit(syncer, 7),
                pool.submit(syncer, 13),
                pool.submit(pruner),
            ]
            try:
                done, pending = concurrent.futures.wait(
                    jobs,
                    timeout=remaining(),
                    return_when=concurrent.futures.FIRST_EXCEPTION,
                )
                for job in done:
                    job.result()
                if pending:
                    raise AssertionError("Concurrent workers exceeded the timeout")
            except BaseException:
                barrier.abort()
                stop_children()
                raise

        # No workers remain: a finite catch-up must reconcile all transient races.
        must("sync", source, target, "replica", "--limit", 7)
        source_status = must("status", source)
        target_status = must("target-status", target)
        assert source_status["cursor"]["sequence"] == str(COMMITS), source_status
        assert target_status["cursor"] == source_status["cursor"], target_status
        consumers = source_status["consumers"]
        assert len(consumers) == 1 and consumers[0]["name"] == "replica", consumers
        assert consumers[0]["sequence"] == str(COMMITS), consumers
        assert not consumers[0]["paused"] and not consumers[0]["stale"], consumers
        assert source_status["journal_contiguous"], source_status
        journal = must("verify", source, "--limit", 1000)
        assert journal["valid"] and journal["cursor"] == source_status["cursor"], journal
        expected = {}
        for value in range(COMMITS):
            expected[value % KEYS] = value
        expected_rows = [
            (key, value, "integer", "integer")
            for key, value in sorted(expected.items())
        ]
        assert rows(source) == expected_rows, "Source lost a committed write"
        assert rows(target) == expected_rows, "Target differs from independent expected rows"
        assert must("audit", source, target)["consistent"], "Final content audit failed"
        print(
            f"PASS: {COMMITS} external commits, two sync workers and concurrent pruning; "
            f"all {KEYS} rows, cursors and retained journal agree; "
            f"{len(races)} recoverable races"
        )


if __name__ == "__main__":
    main()
