#!/usr/bin/env python3
"""Times room opens by what came before them (ROADMAP M19-9): tap → first rows drawn, tap → landed at the newest message.

    scripts/room_open_bench.py                  # 5 rounds on the "Halo Perf" simulator (signed in by scripts/perf.py)
    scripts/room_open_bench.py --rounds 8       # more rounds
    scripts/room_open_bench.py --skip-build     # reuse the last build (shared with scripts/motion_audit.py)

Each round of `HaloPerformanceTests.test6RoomOpenSequence` launches the app afresh and opens, in this order: the fifth chat (the first
room screen of the launch), the same chat again, the sixth chat (new room, not the first screen) and the first chat (one of the top
rooms). The script reads the `room-first-rows` and `room-open` signpost intervals from the simulator's log and prints the median and
the range of each kind of open. Optimised build, like scripts/perf.py; the simulator shows trends, a device the real numbers.
"""
import argparse, datetime, json, os, re, statistics, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from motion_audit import simulator  # noqa: E402

KINDS = ["first room of the launch (5th chat)", "re-open (5th chat)", "new room, not the first (6th chat)", "top room (1st chat)"]
NAMES = ["room-first-rows", "room-open"]


def intervals(udid, since):
    """(name, start, seconds) of every completed Halo performance interval in the simulator's log since `since`."""
    output = subprocess.run(
        ["xcrun", "simctl", "spawn", udid, "log", "show", "--signpost", "--style", "ndjson", "--start", since,
         "--predicate", 'subsystem == "one.mbm.halo" AND category == "performance"'], text=True, capture_output=True).stdout
    begins, found = {}, []
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        # Signpost IDs restart in every process (each round launches the app again).
        name, kind, key = event.get("signpostName"), event.get("signpostType"), (event.get("processID"), event.get("signpostID"))
        if name not in NAMES or key[1] is None:
            continue
        stamp = datetime.datetime.strptime(event["timestamp"][:26], "%Y-%m-%d %H:%M:%S.%f")
        if kind == "begin":
            begins[(name, key)] = stamp
        elif kind == "end" and (name, key) in begins:
            start = begins.pop((name, key))
            found.append((name, start, (stamp - start).total_seconds()))
    return sorted(found, key=lambda item: item[1])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--settle", type=float, default=4)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--derived", default=os.path.join(ROOT, "build/motion-audit/derived"))
    parser.add_argument("--since", help="only read the log from this local time on (YYYY-MM-DD HH:MM:SS) of a run already done")
    arguments = parser.parse_args()
    udid = simulator()
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
    if arguments.since:
        return report(intervals(udid, arguments.since), arguments.rounds)
    if not arguments.skip_build:
        subprocess.run(["xcodebuild", "build-for-testing", "-project", os.path.join(ROOT, "ios/Halo.xcodeproj"), "-scheme", "Halo-Debug",
                        "-destination", f"id={udid}", "-derivedDataPath", arguments.derived, "-quiet",
                        "SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule", "GCC_OPTIMIZATION_LEVEL=s",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS="], check=True, capture_output=True)
    since = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")  # the log's times are the Mac's local time
    # The app version, so the "What's New" sheet stays away (as scripts/perf.py does).
    version = re.search(r"MARKETING_VERSION = (\S+)", open(os.path.join(ROOT, "ios/Config/Base.xcconfig")).read()).group(1)
    env = dict(os.environ, TEST_RUNNER_HALO_RUN_PERF_TESTS="1", TEST_RUNNER_HALO_PERF_VERSION=version, TEST_RUNNER_HALO_BENCH_ROUNDS=str(arguments.rounds),
               TEST_RUNNER_HALO_BENCH_SETTLE=str(arguments.settle))
    test = subprocess.run(
        ["xcodebuild", "test-without-building", "-project", os.path.join(ROOT, "ios/Halo.xcodeproj"), "-scheme", "Halo-Debug",
         "-destination", f"id={udid}", "-derivedDataPath", arguments.derived,
         "-only-testing:HaloUITests/HaloPerformanceTests/test6RoomOpenSequence"], env=env, text=True, capture_output=True)
    if "test6RoomOpenSequence]' passed" not in test.stdout:
        print(test.stdout[-3000:], file=sys.stderr)
        sys.exit("The sequence test did not pass (signed out, or a room did not open).")
    report(intervals(udid, since), arguments.rounds)


def report(found, rounds):
    print(f"{rounds} rounds, simulator, optimised build; seconds, median (min–max)\n")
    print("| Open | tap → first rows drawn | tap → landed at newest |")
    print("|---|---|---|")
    for index, kind in enumerate(KINDS):
        cells = []
        for name in NAMES:
            values = [seconds for (n, _, seconds) in found if n == name]
            if len(values) != len(KINDS) * rounds:
                sys.exit(f"Expected {len(KINDS) * rounds} {name} intervals, found {len(values)}.")
            mine = values[index::len(KINDS)]
            cells.append(f"{statistics.median(mine):.3f} ({min(mine):.3f}–{max(mine):.3f})")
        print(f"| {kind} | {cells[0]} | {cells[1]} |")


if __name__ == "__main__":
    main()
