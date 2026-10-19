#!/usr/bin/env python3
"""Verify and measure the read-only Swift and Rust traversal experiments."""

import argparse
import json
import os
import re
import statistics
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SWIFT = REPO / ".build/release/ScanBenchmark"
RUST = REPO / "Benchmarks/Rust/target/release/sys-cleaner-traversal-bench"
ROOTS = [Path.home() / "Documents/YostarWork/Github", Path.home() / "Documents/YostarWork/Git"]
EXCLUSIONS = {}
VARIANTS = ("swift", "rust_shared", "rust_local")
FIELDS = ("files", "directories", "logical", "allocated", "omitted", "cancelled", "folders")


def command(variant, root, workers, extra=()):
    exclude = EXCLUSIONS.get(str(root))
    options = ["--exclude", str(exclude)] if exclude else []
    if variant == "swift":
        return [str(SWIFT), "matched", str(root), str(workers), *options, *extra]
    if variant == "production":
        return [str(SWIFT), "production", str(root), "4", *options, *extra]
    return [str(RUST), "shared" if variant == "rust_shared" else "local",
            str(root), str(workers), *options, *extra]


def execute(variant, root, workers, extra=(), measure=False):
    cmd = command(variant, root, workers, extra)
    if measure:
        cmd = ["/usr/bin/time", "-l", *cmd]
    started = time.perf_counter()
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300, check=True)
    elapsed = time.perf_counter() - started
    data = json.loads(result.stdout)
    if "folders" in data and data["folders"] is not None:
        data["folders"] = {os.path.realpath(path): totals
                           for path, totals in data["folders"].items()}
    if not measure:
        return data
    match = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
    if not match:
        raise RuntimeError(f"missing maximum resident set size: {result.stderr}")
    return data, round(elapsed, 6), int(match.group(1))


def compare(expected, actual, label):
    differences = {key: (expected.get(key), actual.get(key))
                   for key in FIELDS if expected.get(key) != actual.get(key)}
    if differences:
        # Avoid dumping thousands of folder names into the terminal.
        if "folders" in differences:
            left, right = differences["folders"]
            differing = [key for key in set(left or {}) | set(right or {})
                         if (left or {}).get(key) != (right or {}).get(key)]
            differences["folders"] = {"count": len(differing), "sample": differing[:5]}
        raise AssertionError(f"{label}: {differences}")


def verify_fixture():
    with tempfile.TemporaryDirectory(prefix="sys-cleaner-traversal-") as directory:
        root = Path(directory).resolve()
        deep = root / "a/b/c/d/e"
        deep.mkdir(parents=True)
        (deep / "data").write_bytes(b"alpha" * 31)
        os.link(deep / "data", root / "hardlink")
        (root / "empty").mkdir()
        (root / ".Trash").mkdir()
        (root / ".Trash/ignored").write_bytes(b"ignored")
        (root / "link").symlink_to(deep, target_is_directory=True)
        (root / "outside").symlink_to(Path.home(), target_is_directory=True)
        unreadable = root / "unreadable"
        unreadable.mkdir()
        (unreadable / "hidden").write_bytes(b"hidden")
        unreadable.chmod(0)
        try:
            expected = execute("swift", root, 1, ["--manifest"])
            assert expected["files"] == 2, expected
            assert expected["logical"] == 310, expected
            assert expected["directories"] == 8, expected
            assert expected["omitted"] == 1, expected
            assert str(root / ".Trash") not in expected["folders"]
            for variant in VARIANTS:
                for workers in (1, 4, 8):
                    compare(expected, execute(variant, root, workers, ["--manifest"]),
                            f"fixture {variant}/{workers}")
            compare(expected, execute("production", root, 4, ["--manifest"]), "fixture production")
        finally:
            unreadable.chmod(0o700)

        for index in range(2000):
            (root / f"cancel-{index:04d}").write_bytes(b"x")
        for variant in VARIANTS:
            for workers in (1, 4, 8):
                result = execute(variant, root, workers, ["--cancel-after", "1"])
                assert result["cancelled"] and result["files"] < 2002, (variant, workers, result)
    print("fixture: deep folders, symlinks, hardlink, .Trash, unreadable folder, cancellation: PASS", flush=True)


def verify_cross_volume():
    with tempfile.TemporaryDirectory(prefix="sys-cleaner-cross-volume-") as directory:
        base = Path(directory).resolve()
        root = base / "root"
        root.mkdir()
        mount = root / "mounted"
        mount.mkdir()
        image = base / "volume.sparseimage"
        subprocess.run(["hdiutil", "create", "-size", "16m", "-fs", "HFS+",
                        "-volname", "SysCleanerBench", "-type", "SPARSE", "-quiet", str(image)],
                       check=True, timeout=120)
        attached = False
        try:
            subprocess.run(["hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint",
                            str(mount), str(image)], check=True, timeout=120)
            attached = True
            assert os.stat(root).st_dev != os.stat(mount).st_dev
            (mount / "other-volume-file").write_bytes(b"cross-volume")
            expected = execute("swift", root, 1, ["--manifest"])
            assert expected["files"] == 0 and expected["directories"] == 1, expected
            for variant in VARIANTS:
                for workers in (1, 4, 8):
                    compare(expected, execute(variant, root, workers, ["--manifest"]),
                            f"cross-volume {variant}/{workers}")
            compare(expected, execute("production", root, 4, ["--manifest"]),
                    "cross-volume production")
        finally:
            if attached:
                subprocess.run(["hdiutil", "detach", "-quiet", str(mount)],
                               check=True, timeout=120)
    print("fixture: mounted second volume: PASS", flush=True)


def verify_roots():
    summaries = {}
    for root in ROOTS:
        if not root.is_dir():
            raise FileNotFoundError(root)
        expected = execute("swift", root, 4, ["--manifest"])
        for variant in VARIANTS:
            for workers in (1, 4, 8):
                compare(expected, execute(variant, root, workers, ["--manifest"]),
                        f"{root} {variant}/{workers}")
        compare(expected, execute("production", root, 4, ["--manifest"]),
                f"{root} production")
        summaries[str(root)] = {key: value for key, value in expected.items() if key != "folders"}
        print(f"parity: {root}: {summaries[str(root)]}", flush=True)
    return summaries


def version(command):
    return subprocess.check_output(command, text=True).strip()


def measure(summaries, destination):
    record = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "host": version(["uname", "-sm"]),
        "swift": version(["swift", "--version"]),
        "rustc": version([str(Path.home() / ".cargo/bin/rustc"), "--version"]),
        "cargo": version([str(Path.home() / ".cargo/bin/cargo"), "--version"]),
        "roots": summaries,
        "exclusions": {root: str(path) for root, path in EXCLUSIONS.items() if root in summaries},
        "unit": {"seconds": "wall clock", "rss_bytes": "maximum resident set size from /usr/bin/time -l"},
        "runs": [],
    }
    destination.parent.mkdir(parents=True, exist_ok=True)

    def save():
        destination.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")

    for root in ROOTS:
        root_summary = summaries[str(root)]
        configs = [(variant, workers) for workers in (1, 4, 8) for variant in VARIANTS]
        configs.append(("production", 4))
        for repetition in range(6):
            ordered = configs if repetition % 2 == 0 else list(reversed(configs))
            for variant, workers in ordered:
                data, seconds, rss = execute(variant, root, workers, measure=True)
                for key in ("files", "directories", "logical", "allocated", "omitted", "cancelled"):
                    if data[key] != root_summary[key]:
                        raise AssertionError(f"result changed during timing: {root}, {variant}, {workers}, {key}")
                item = {"root": str(root), "variant": variant, "workers": workers,
                        "repetition": repetition, "phase": "first" if repetition == 0 else "repeat",
                        "seconds": seconds, "rss_bytes": rss}
                record["runs"].append(item)
                save()
                print(f"{root.name:6s} {variant:11s} {workers} run {repetition}: {seconds:.3f}s {rss/1048576:.1f} MiB", flush=True)
    return record


def summarize(record):
    for root in ROOTS:
        print(f"\n{root}:")
        for workers in (1, 4, 8):
            for variant in VARIANTS:
                runs = [item for item in record["runs"] if item["root"] == str(root)
                        and item["variant"] == variant and item["workers"] == workers]
                warm = [item["seconds"] for item in runs if item["phase"] == "repeat"]
                print(f"  {variant:11s} {workers}: first {runs[0]['seconds']:.3f}s; "
                      f"repeat median {statistics.median(warm):.3f}s; "
                      f"peak RSS {max(item['rss_bytes'] for item in runs)/1048576:.1f} MiB")
        runs = [item for item in record["runs"] if item["root"] == str(root)
                and item["variant"] == "production"]
        print(f"  production   4: first {runs[0]['seconds']:.3f}s; "
              f"repeat median {statistics.median(item['seconds'] for item in runs[1:]):.3f}s")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--root", action="append", type=Path,
                        help="run one or more chosen roots (default: Github and Git)")
    parser.add_argument("--exclude", action="append", type=Path,
                        help="exclude an active subtree from every implementation")
    parser.add_argument("--output", type=Path,
                        default=Path(tempfile.gettempdir()) / "sys-cleaner-benchmark.json")
    args = parser.parse_args()
    if args.root:
        global ROOTS
        ROOTS = [root.expanduser().resolve() for root in args.root]
    if args.exclude:
        global EXCLUSIONS
        for path in args.exclude:
            path = path.expanduser().resolve()
            matching = [root for root in ROOTS if root in path.parents]
            if len(matching) != 1 or str(matching[0]) in EXCLUSIONS:
                parser.error(f"each exclusion must belong to exactly one root: {path}")
            EXCLUSIONS[str(matching[0])] = path
    destination = args.output.expanduser().resolve()
    if any(destination == root or root in destination.parents for root in ROOTS):
        parser.error("output must be outside scanned roots; copy the final JSON into the repo afterward")
    if not SWIFT.is_file() or not RUST.is_file():
        raise SystemExit("build both release executables first; see Benchmarks/README.md")
    verify_fixture()
    verify_cross_volume()
    summaries = verify_roots()
    if not args.verify_only:
        summarize(measure(summaries, destination))


if __name__ == "__main__":
    main()
