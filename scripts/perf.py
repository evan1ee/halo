#!/usr/bin/env python3
"""Runs the performance suite and judges it: budget / measured / baseline / pass (TEST_STRATEGY §7, ROADMAP M17-5).

    scripts/perf.py                         # a simulator of its own ("Halo Perf"), accounts of the M17-3 scale fixture
    scripts/perf.py --accounts scale300     # only some of them (scale300, scale1000, scalebig)
    scripts/perf.py --device <udid>         # a physical device, with the account it is signed in to (label it: --label small)
    scripts/perf.py --save-baseline         # accept these values as the baseline of this device

Optimised code in the Debug app (its Info.plist may reach local servers): -O, whole module, no DEBUG flag. Exit status 1 when a value is more
than 20 % (and the noise floor) worse than the baseline of the same device, or, on a physical device, over its budget. A simulator shows trends only, so a
missed budget there is printed but doesn't fail. Baselines: docs/testing/perf-baseline.json.
The scale fixture must be up (`infra/dev/scale-fixtures.py up`) unless --device is given.
"""
import argparse, glob, json, os, re, shutil, statistics, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "docs/testing/perf-baseline.json")
SCALE = os.environ.get("HALO_SCALE_DIR", os.path.expanduser("~/.config/halo-dev/scale"))
SIMULATOR, SIMULATOR_TYPE = "Halo Perf", "iPhone 17"
SETTLE = {"scale300": 60, "scale1000": 150, "scalebig": 45}
# Which tests each account is for; a physical device runs all of them on its own account.
TESTS = {"scale300": ["test1ColdStart", "test2RoomOpen", "test5Idle"], "scale1000": ["test1ColdStart", "test5Idle"],
         "scalebig": ["test3Scroll", "test4Cycles"]}


def p95(values): return sorted(values)[max(0, -(-95 * len(values) // 100) - 1)]


# name, test, pattern of the metric's identifier, how to reduce its values, unit, budget, differences below this are noise
MEASURES = [
    ("NFR-1 launch → responsive", "test1ColdStart", r"applicationlaunch|ApplicationLaunch", statistics.median, "s", 1.0, 0.1),
    ("NFR-1 cold-start signpost", "test1ColdStart", r"cold-start", statistics.median, "s", 1.0, 0.1),
    ("NFR-11 room open, p95", "test2RoomOpen", r"room-open", p95, "s", 0.25, 0.05),
    ("NFR-2 scroll hitch time ratio", "test3Scroll", r"(?i)hitch.*ratio|hitchTimeRatio", statistics.median, "ms/s", 5.0, 1.0),
    ("NFR-12 peak memory, media scrolling", "test3Scroll", r"(?i)memory.*peak", max, "MB", 200.0, 10.0),
    ("NFR-12 peak memory, 50 cycles", "test4Cycles", r"(?i)memory.*peak", max, "MB", 300.0, 10.0),
    ("NFR-12 growth over 50 cycles", "test4Cycles", r"(?i)memory\.physical(?!.*(peak|absolute))", sum, "MB", None, 5.0),
    ("NFR-13 hangs ≥ 250 ms, scrolling", "test3Scroll", r"main-thread-hang", len, "", 0, 1),
    ("NFR-13 hangs ≥ 250 ms, 50 cycles", "test4Cycles", r"main-thread-hang", len, "", 0, 1),
    ("NFR-15 CPU in an idle minute", "test5Idle", r"(?i)cpu\.time", statistics.median, "s", None, 0.3),
]


def run(command, **options): return subprocess.run(command, check=True, text=True, capture_output=True, **options).stdout


def simulator():
    devices = [d for group in json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"].values() for d in group]
    found = next((d["udid"] for d in devices if d["name"] == SIMULATOR), None)
    return found or run(["xcrun", "simctl", "create", SIMULATOR, SIMULATOR_TYPE]).strip()


def measure(destination, tests, env, bundle):
    only = [f"-only-testing:HaloUITests/HaloPerformanceTests/{test}" for test in ["test0SignIn", *tests]]
    # Build products of its own (other settings), but the packages Xcode already has: they can be large and the network may be away.
    checkouts = sorted(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/Halo-*/SourcePackages")), key=os.path.getmtime)
    packages = ["-clonedSourcePackagesDirPath", checkouts[-1], "-disableAutomaticPackageResolution"] if checkouts else []
    version = re.search(r"MARKETING_VERSION = (\S+)", open(os.path.join(ROOT, "ios/Config/Base.xcconfig")).read()).group(1)
    result = subprocess.run(
        ["xcodebuild", "-project", "ios/Halo.xcodeproj", "-scheme", "Halo-Debug", "-destination", destination, "-resultBundlePath", bundle, *only,
         "SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule", "GCC_OPTIMIZATION_LEVEL=s", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=",
         "ENABLE_TESTABILITY=NO", "-derivedDataPath", os.path.expanduser("~/Library/Caches/halo-perf"), *packages, "test"],
        cwd=ROOT, env=dict(os.environ, TEST_RUNNER_HALO_RUN_PERF_TESTS="1", TEST_RUNNER_HALO_PERF_VERSION=version, **env), text=True, capture_output=True)
    for line in result.stdout.splitlines():
        if re.search(r"error:|Test Case .*(failed|skipped)", line):
            print("  " + line[:220], file=sys.stderr)
    if result.returncode:
        print(f"  xcodebuild exit {result.returncode}", file=sys.stderr)
    values = {}
    for test in json.loads(run(["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", bundle, "--compact"])):
        name = re.sub(r"\(\)$", "", test["testIdentifier"].split("/")[-1])
        for one in test["testRuns"]:
            for metric in one["metrics"]:
                values.setdefault(name, {})[metric["identifier"]] = (metric["unitOfMeasurement"], metric["measurements"])
    return values, result.returncode == 0


def evaluate(values):
    """{measure: value}; missing when the test didn't produce it."""
    found = {}
    for name, test, pattern, reduce, unit, _, _ in MEASURES:
        metrics = values.get(test)
        if not metrics:
            continue
        matching = [v for key, v in metrics.items() if re.search(pattern, key)]
        if not matching:
            if reduce is len:
                found[name] = 0  # no interval: no hang
            continue
        source, numbers = matching[0]
        scale = {("kB", "MB"): 1 / 1000, ("ms", "s"): 1 / 1000}.get((source, unit), 1)
        found[name] = reduce(numbers) if reduce is len else reduce([n * scale for n in numbers])
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--accounts", nargs="*", choices=list(TESTS), default=list(TESTS))
    parser.add_argument("--device")
    parser.add_argument("--label", default="signed-in account")
    parser.add_argument("--save-baseline", action="store_true")
    parser.add_argument("--keep", action="store_true", help="keep the result bundles and print where they are")
    options = parser.parse_args()
    work = tempfile.mkdtemp(prefix="halo-perf-")
    results, ok = {}, True
    if options.device:
        key = f"device {options.device[:8]}"
        values, passed = measure(f"platform=iOS,id={options.device}", sorted({t for ts in TESTS.values() for t in ts}), {}, os.path.join(work, "device.xcresult"))
        results[options.label], ok = evaluate(values), passed
    else:
        udid, passwords = simulator(), json.load(open(os.path.join(SCALE, "passwords.json")))
        key = f"simulator {SIMULATOR_TYPE}"
        for account in options.accounts:
            print(f"measuring {account} …", file=sys.stderr, flush=True)
            subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
            run(["xcrun", "simctl", "erase", udid])  # a simulator of this script's own: nothing else is signed in there
            values, passed = measure(f"platform=iOS Simulator,id={udid}", TESTS[account], {
                "TEST_RUNNER_HALO_PERF_SERVER": f"http://localhost:{os.environ.get('HALO_SCALE_PORT', '8108')}", "TEST_RUNNER_HALO_PERF_USER": account,
                "TEST_RUNNER_HALO_PERF_PASSWORD": passwords[account], "TEST_RUNNER_HALO_PERF_SETTLE": str(SETTLE[account]),
                "TEST_RUNNER_HALO_PERF_MEDIA_ROOM": "Twenty thousand events"}, os.path.join(work, account + ".xcresult"))
            results[account], ok = evaluate(values), ok and passed
        subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)

    baselines = json.load(open(BASELINE)) if os.path.exists(BASELINE) else {}
    known = baselines.get(key, {})
    print(f"| Budget | Account | Target | Measured | Baseline | Result |\n|---|---|---|---|---|---|")
    for account, found in results.items():
        for name, test, _, _, unit, budget, noise in MEASURES:
            if not options.device and test not in TESTS[account]:
                continue
            value, before = found.get(name), known.get(account, {}).get(name)
            show = lambda v: "—" if v is None else f"{v:.3g} {unit}".strip()
            if value is None:
                verdict = "**not measured**"
                ok = ok and not options.device
            elif before is not None and value > before * 1.2 and value - before > noise:
                verdict, ok = "**worse**", False
            elif budget is not None and value > budget:
                verdict = "**over**" if options.device else "over (simulator)"
                ok = ok and not options.device
            else:
                verdict = "pass"
            print(f"| {name} | {account} | {'record' if budget is None else '≤ ' + show(budget)} | {show(value)} | {show(before)} | {verdict} |")
    if options.save_baseline:
        for account, found in results.items():
            baselines.setdefault(key, {}).setdefault(account, {}).update({k: round(v, 4) for k, v in found.items()})
        with open(BASELINE, "w") as f:
            json.dump(baselines, f, indent=1, sort_keys=True, ensure_ascii=False)
            f.write("\n")
    if options.keep:
        print(work, file=sys.stderr)
    else:
        shutil.rmtree(work, ignore_errors=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
