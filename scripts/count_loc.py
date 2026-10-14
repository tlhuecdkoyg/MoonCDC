"""Count nonblank, noncomment production MoonBit lines (not physical file size)."""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXCLUDED = {"_build", "target", ".mooncakes", ".git", "examples", "tests"}


def count():
    result = {}
    for path in sorted(ROOT.rglob("*.mbt")):
        relative = path.relative_to(ROOT)
        if any(part in EXCLUDED for part in relative.parts):
            continue
        if path.name.endswith(("_test.mbt", "_wbtest.mbt")) or path.name == "traits.mbt":
            continue
        lines = path.read_text(encoding="utf-8-sig").splitlines()
        result[relative.as_posix()] = sum(
            bool(line.strip()) and not line.lstrip().startswith(("//", "#|"))
            for line in lines
        )
    return result


if __name__ == "__main__":
    files = count()
    print(json.dumps({"production_moonbit_lines": sum(files.values()), "files": files}, indent=2))
    if sum(files.values()) < 4000:
        raise SystemExit("Production MoonBit source has fewer than 4000 effective lines")
