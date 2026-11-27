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
SCENARIOS = [
    "launch", "room-open-close", "room-open-other", "keyboard", "send", "reaction",
    "edit", "appearance", "background", "scroll-up", "history-prepend", "reconnect",
]
FPS = 30
# A frame differs from the one before it when its average brightness changes by more than this (0-255 scale).
THRESHOLD = 0.35
# Calibration pulse (light -> dark -> light while the app is open after mark("end")) produces two large global brightness steps (~155-240).
CALIBRATION_STEP = 140.0
# Scenarios whose transition window must never show a flat blank message area (AC-MOT-1).
NO_BLANK_SCENARIOS = {"room-open-close", "room-open-other", "send", "reaction", "edit", "appearance", "reconnect"}
# A message area whose luma range (YMAX - YMIN) is at or below this is a flat blank frame.
BLANK_RANGE = 6.0


def run(command, **options): return subprocess.run(command, check=True, text=True, capture_output=True, **options).stdout


def simulator(name="Halo Perf"):
    devices = [d for group in json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"].values() for d in group]
    found = next((d["udid"] for d in devices if d["name"] == name), None)
    if not found: sys.exit(f'No simulator named "{name}": run scripts/perf.py once so it exists and is signed in.')
    return found


def docker_container(action, name="halo-scale-synapse-1"):
    env = dict(os.environ, DOCKER_CONFIG=os.environ.get("DOCKER_CONFIG", "/tmp/halo-docker-motion"))
    os.makedirs(env["DOCKER_CONFIG"], exist_ok=True)
    if not os.path.exists(os.path.join(env["DOCKER_CONFIG"], "config.json")):
        open(os.path.join(env["DOCKER_CONFIG"], "config.json"), "w").write("{}\n")
    subprocess.run(["docker", action, name], env=env, capture_output=True)


def film(udid, scenario, out, derived):
    movie = os.path.join(out, scenario + ".mp4")
    if os.path.exists(movie): os.remove(movie)
    marks = os.path.abspath(os.path.join(out, scenario + ".marks"))
    open(marks, "w").close()
    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "light"], capture_output=True)
    time.sleep(0.2)
    recorder = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", movie], stderr=subprocess.DEVNULL)
    deadline = time.time() + 15
    while time.time() < deadline and not (os.path.exists(movie) and os.path.getsize(movie) > 0):
        time.sleep(0.05)  # the file appears when the recorder takes its first frame
    started = time.time()
    env = dict(os.environ, TEST_RUNNER_HALO_MOTION_SCENARIO=scenario, TEST_RUNNER_HALO_MOTION_MARKS=marks)
    # Scenarios can ask the script to act on the simulator or server by writing a mark.
    stop = threading.Event()
    paused_server = [False]
    cal_wall = [None]
    def watch():
        done = set()
        while not stop.is_set():
            for line in open(marks):
                name = line.split()[0] if line.strip() else ""
                if line in done:
                    continue
                if name in ("dark", "light"):
                    done.add(line)
                    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", name], capture_output=True)
                elif name == "offline":
                    done.add(line)
                    paused_server[0] = True
                    docker_container("pause")
                elif name == "online":
                    done.add(line)
                    paused_server[0] = False
                    docker_container("unpause")
                elif name == "calibrate":
                    done.add(line)
                    # Exact wall-clock <-> video-frame calibration: flip light -> dark -> light while the app is open on screen.
                    cal_wall[0] = time.time()
                    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "dark"], capture_output=True)
                    time.sleep(0.35)
                    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "light"], capture_output=True)
                    with open(marks, "a") as handle:
                        handle.write(f"calibrated {time.time()}\n")
            time.sleep(0.02)
    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    try:
        test = subprocess.run(
            ["xcodebuild", "test-without-building", "-project", os.path.join(ROOT, "ios/Halo.xcodeproj"), "-scheme", "Halo-Debug",
             "-destination", f"id={udid}", "-derivedDataPath", derived, "-only-testing:HaloUITests/HaloUITests/testMotionAudit"],
            env=env, text=True, capture_output=True)
    finally:
        stop.set()
        if paused_server[0]:
            docker_container("unpause")
        subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "light"], capture_output=True)
        time.sleep(0.5)
        recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=30)
    ok = "testMotionAudit]' passed" in test.stdout
    times = {line.split()[0]: float(line.split()[1]) for line in open(marks) if line.strip()}
    window = (times["begin"], times["end"]) if {"begin", "end"} <= times.keys() else None
    return movie, ok and window is not None, window, cal_wall[0], started


def steps(movie):
    """The brightness change between each frame and the one before it, from ffmpeg's difference blend."""
    output = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", movie, "-vf", f"fps={FPS},scale=200:-1,format=gray,tblend=all_mode=difference,signalstats,metadata=print:file=-",
         "-f", "null", "-"], text=True, capture_output=True).stdout
    return [float(m.group(1)) for m in re.finditer(r"lavfi\.signalstats\.YAVG=([0-9.]+)", output)]


def blank_flags(movie):
    """Per-frame boolean: True when the central message region is nearly one flat colour (empty message area)."""
    output = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", movie, "-vf",
         f"fps={FPS},crop=iw*0.7:ih*0.4:iw*0.15:ih*0.25,format=gray,signalstats,metadata=print:file=-",
         "-f", "null", "-"], text=True, capture_output=True).stdout
    ymins = [float(m.group(1)) for m in re.finditer(r"lavfi\.signalstats\.YMIN=([0-9.]+)", output)]
    ymaxs = [float(m.group(1)) for m in re.finditer(r"lavfi\.signalstats\.YMAX=([0-9.]+)", output)]
    return [(hi - lo) <= BLANK_RANGE for lo, hi in zip(ymins, ymaxs)]


def calibration_frame(values):
    """Finds the exact frame of the post-test dark/light calibration pulse (last pair of >=25 steps, 5-25 frames apart)."""
    spikes = [i for i, v in enumerate(values) if v >= CALIBRATION_STEP]
    for idx in range(len(spikes) - 1, 0, -1):
        second = spikes[idx]
        for prev in range(idx - 1, -1, -1):
            gap = second - spikes[prev]
            if 5 <= gap <= 25:
                return spikes[prev]
            if gap > 25:
                break
    return None


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
    parser.add_argument("--assert", dest="assert_clean", action="store_true",
                        help="Exit non-zero if any scenario fails or a no-blank transition shows blank frames.")
    arguments = parser.parse_args()
    os.makedirs(arguments.out, exist_ok=True)
    udid = simulator()
    derived = os.path.join(arguments.out, "derived")
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
    # The Mac's keyboard counts as a hardware keyboard, so the simulator hides the software one and typed text stops after a few characters.
    subprocess.run(["xcrun", "simctl", "spawn", udid, "defaults", "write", "com.apple.keyboard.preferences", "AutomaticMinimizationEnabled", "-bool", "NO"], capture_output=True)
    if not arguments.skip_build:
        subprocess.run(["xcodebuild", "build-for-testing", "-project", os.path.join(ROOT, "ios/Halo.xcodeproj"), "-scheme", "Halo-Debug",
                        "-destination", f"id={udid}", "-derivedDataPath", derived, "-quiet",
                        # Optimised like scripts/perf.py: an unoptimised build lays lists out several times slower and the film exaggerates.
                        "SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule", "GCC_OPTIMIZATION_LEVEL=s",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS="], check=True, capture_output=True)
    report = ["| Scenario | Burst | Frames (30 fps) | Length | Largest step | Blank frames | Strip |", "|---|---|---|---|---|---|---|"]
    failures = []
    for scenario in arguments.scenarios:
        movie, ok, window, cal_wall, started = film(udid, scenario, arguments.out, derived)
        if not ok:
            report.append(f"| {scenario} | — | — | — | — | — | **the test did not pass** (skipped when signed out) |")
            failures.append(f"{scenario}: test failed")
            continue
        values = steps(movie)
        blanks = blank_flags(movie)
        cal = calibration_frame(values)
        if cal is not None and cal_wall is not None:
            # Exact alignment against the post-end dark/light calibration pulse; clip before the pulse itself.
            low = max(0, int(round(cal - (cal_wall - window[0]) * FPS)))
            high = min(max(0, cal - 3), int(round(cal - (cal_wall - window[1]) * FPS)))
        else:
            low = max(0, int(round((window[0] - started) * FPS)))
            high = min(len(values) - 1, int(round((window[1] - started) * FPS)))
        matched = [(a, b) for a, b in bursts(values) if b >= low and a <= high]
        if not matched:
            report.append(f"| {scenario} | 0 | {low}–{high} | 0.00 s | 0.0 | 0 | (no burst in window) |")
        for number, (first, last) in enumerate(matched, 1):
            clipped_first = max(low, first)
            clipped_last = min(high, last)
            path = os.path.join(arguments.out, f"{scenario}-burst-{number}.png")
            strip(movie, max(0, clipped_first - 1), min(len(values) - 1, clipped_last + 1), path)
            blank_count = sum(1 for i in range(clipped_first, min(len(blanks), clipped_last + 1)) if blanks[i])
            if scenario in NO_BLANK_SCENARIOS and blank_count > 0:
                failures.append(f"{scenario} burst {number}: {blank_count} blank frame(s)")
            report.append(
                f"| {scenario} | {number} | {clipped_first}–{clipped_last} | {(clipped_last - clipped_first + 1) / FPS:.2f} s "
                f"| {max(values[clipped_first:clipped_last + 1]):.1f} | {blank_count} | {os.path.relpath(path, ROOT)} |"
            )
    print("\n".join(report))
    if arguments.assert_clean and failures:
        sys.exit("Motion audit assertions failed: " + "; ".join(failures))


if __name__ == "__main__":
    main()
