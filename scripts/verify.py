"""Fail-fast local/CI verification. Run from any directory with moon/node/python on PATH."""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(*args):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True)


def main():
    run("moon", "version", "--all")
    run("moon", "fmt", "--check")
    run("moon", "check", "--target", "native", "--deny-warn")
    for target in ("native", "js", "wasm-gc"):
        run("moon", "test", "--target", target, "--deny-warn")
    run("moon", "build", "--target", "native", "--deny-warn")
    run("moon", "info", "--target", "native")
    run(sys.executable, "scripts/count_loc.py")
    executable = ROOT / "_build/native/debug/build/cmd/main/main.exe"
    # moon uses .exe for native executables on both Windows and Linux.
    run(sys.executable, "scripts/integration.py", executable)
    run(sys.executable, "scripts/real_regression.py", executable)
    run(sys.executable, "scripts/concurrency_regression.py", executable)
    run(sys.executable, "scripts/compatibility_regression.py")
    run(sys.executable, "scripts/conflict_regression.py", executable)
    run(sys.executable, "scripts/schema_regression.py", executable)
    run(sys.executable, "scripts/commit_failure_regression.py", executable)
    run(sys.executable, "scripts/crash_recovery_regression.py", executable)
    run(sys.executable, "scripts/framing_regression.py", executable)


if __name__ == "__main__":
    main()
