#!/usr/bin/env python3
"""Films transitions of the app in a simulator and finds frames that move or blank (ROADMAP M19-9, AC-MOT-1).

    scripts/motion_audit.py                      # every scenario on the "Halo Perf" simulator (signed in by scripts/perf.py)
    scripts/motion_audit.py keyboard send        # only these
    scripts/motion_audit.py --out DIR            # where the films, frame strips and the report go (default build/motion-audit)

For each scenario of `HaloUITests.testMotionAudit` it records the simulator screen while the UI test runs, then asks ffmpeg for the
difference between neighbouring frames. A run of frames that differ is a "burst" (something moved); each burst gets a strip of its frames
(`<scenario>-burst-N.png`, one frame per cell, left to right) to be read by eye, and a table of how long it lasted and how big the largest
step between two frames was. A frame that is nearly one flat colour in the middle of the content is listed as blank. Needs ffmpeg.
"""
import argparse, glob, json, os, re, signal, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENARIOS = ["launch", "room-open-close", "keyboard", "send", "reaction", "appearance", "background", "scroll-up"]
FPS = 30
# A frame differs from the one before it when its average brightness changes by more than this (0-255 scale).
THRESHOLD = 0.35


def run(command, **options): return subprocess.run(command, check=True, text=True, capture_output=True, **options).stdout


def simulator(name="Halo Perf"):
    devices = [d for group in json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"].values() for d in group]
    found = next((d["udid"] for d in devices if d["name"] == name), None)
    if not found: sys.exit(f'No simulator named "{name}": run scripts/perf.py once so it exists and is signed in.')
    return found


def film(udid, scenario, out, derived):
    movie = os.path.join(out, scenario + ".mp4")
    if os.path.exists(movie): os.remove(movie)
    marks = os.path.abspath(os.path.join(out, scenario + ".marks"))
    open(marks, "w").close()
    recorder = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", movie], stderr=subprocess.DEVNULL)
    deadline = time.time() + 15
    while time.time() < deadline and not (os.path.exists(movie) and os.path.getsize(movie) > 0):
        time.sleep(0.05)  # the file appears when the recorder takes its first frame
    started = time.time()
    time.sleep(1)
    env = dict(os.environ, TEST_RUNNER_HALO_MOTION_SCENARIO=scenario, TEST_RUNNER_HALO_MOTION_MARKS=marks)
    # Scenarios can ask the script to act on the simulator by writing a mark: "dark" or "light" switches its appearance.
    stop = threading.Event()
    def watch():
        done = set()
        while not stop.is_set():
            for line in open(marks):
                name = line.split()[0] if line.strip() else ""
                if name in ("dark", "light") and line not in done:
                    done.add(line)
                    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", name], capture_output=True)
            time.sleep(0.05)
    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    test = subprocess.run(
        ["xcodebuild", "test-without-building", "-project", os.path.join(ROOT, "ios/Halo.xcodeproj"), "-scheme", "Halo-Debug",
         "-destination", f"id={udid}", "-derivedDataPath", derived, "-only-testing:HaloUITests/HaloUITests/testMotionAudit"],
        env=env, text=True, capture_output=True)
    stop.set()
    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "light"], capture_output=True)
    time.sleep(1)
    recorder.send_signal(signal.SIGINT)
    recorder.wait(timeout=30)
    ok = "testMotionAudit]' passed" in test.stdout
    times = {line.split()[0]: float(line.split()[1]) for line in open(marks) if line.strip()}
    window = (times["begin"] - started, times["end"] - started) if {"begin", "end"} <= times.keys() else None
    return movie, ok and window is not None, window


def steps(movie):
    """The brightness change between each frame and the one before it, from ffmpeg's difference blend."""
    output = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", movie, "-vf", f"fps={FPS},scale=200:-1,format=gray,tblend=all_mode=difference,signalstats,metadata=print:file=-",
         "-f", "null", "-"], text=True, capture_output=True).stdout
    return [float(m.group(1)) for m in re.finditer(r"lavfi\.signalstats\.YAVG=([0-9.]+)", output)]


def bursts(values, gap=6):
    found, start, quiet = [], None, 0
    for index, value in enumerate(values):
        if value > THRESHOLD:
            if start is None: start = index
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet >= gap:
                found.append((start, index - quiet)); start, quiet = None, 0
    if start is not None: found.append((start, len(values) - 1))
    return found


def strip(movie, first, last, path):
    count = max(1, last - first + 1)
    columns = min(count, 12)
    rows = -(-count // columns)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", movie, "-vf",
         f"fps={FPS},select='between(n,{first},{last})',scale=160:-1,tile={columns}x{rows}", "-frames:v", "1", path], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scenarios", nargs="*", default=SCENARIOS)
    parser.add_argument("--out", default=os.path.join(ROOT, "build/motion-audit"))
    parser.add_argument("--skip-build", action="store_true")
    arguments = parser.parse_args()
    os.makedirs(arguments.out, exist_ok=True)
    udid = simulator()
    derived = os.path.join(arguments.out, "derived")
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
    if not arguments.skip_build:
        subprocess.run(["xcodebuild", "build-for-testing", "-project", os.path.join(ROOT, "ios/Halo.xcodeproj"), "-scheme", "Halo-Debug",
                        "-destination", f"id={udid}", "-derivedDataPath", derived, "-quiet"], check=True, capture_output=True)
    report = ["| Scenario | Burst | Frames (30 fps) | Length | Largest step | Strip |", "|---|---|---|---|---|---|"]
    for scenario in arguments.scenarios:
        movie, ok, window = film(udid, scenario, arguments.out, derived)
        if not ok:
            report.append(f"| {scenario} | — | — | — | — | **the test did not pass** (skipped when signed out) |")
            continue
        values = steps(movie)
        # Only the scenario itself: from the "begin" mark to the "end" mark, plus the frames the film needs to settle after the first.
        low, high = max(0, int(window[0] * FPS)), min(len(values) - 1, int(window[1] * FPS))
        for number, (first, last) in enumerate([(a, b) for a, b in bursts(values) if b >= low and a <= high], 1):
            path = os.path.join(arguments.out, f"{scenario}-burst-{number}.png")
            strip(movie, max(0, first - 1), min(len(values) - 1, last + 1), path)
            report.append(f"| {scenario} | {number} | {first}–{last} | {(last - first + 1) / FPS:.2f} s | {max(values[first:last + 1]):.1f} | {os.path.relpath(path, ROOT)} |")
    print("\n".join(report))


if __name__ == "__main__":
    main()
