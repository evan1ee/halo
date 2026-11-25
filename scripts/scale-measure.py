#!/usr/bin/env python3
"""Measures classic sync on the M17-3 scale fixture (ROADMAP M17-4) and prints one table row per account.

    scripts/scale-measure.py [scale300|scale1000|scalebig …]     (default: all three)
    scripts/scale-measure.py --search [scale1000|scalebig]       message search reads the full history (M19-11); prints raw JSON

HALO_SCALE_SEARCH=1 (default) measures with message search as shipped, =paginate without it, =0 also without automatic back-pagination. Needs `infra/dev/scale-fixtures.py up` to have finished. HALO_SIM picks the simulator. Numbers from a simulator run on the Mac's CPU and
network: they show the amount of work (bytes, requests, memory, store) and trends, not what an iPhone takes (TEST_STRATEGY §7).
Raw results go to ~/.config/halo-dev/scale/results-<time>.json; no identifiers or passwords are printed.
"""
import json, os, re, subprocess, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.environ.get("HALO_SCALE_DIR", os.path.expanduser("~/.config/halo-dev/scale"))
PORT, PROXY, CONTROL = int(os.environ.get("HALO_SCALE_PORT", "8108")), 8118, 8119
ROOMS = {"scale300": 300, "scale1000": 1000, "scalebig": 2}


def traffic(stats, only=""):
    rows = [v for k, v in (stats or {}).items() if only in k]
    return sum(v["requests"] for v in rows), sum(v["bytes_down"] for v in rows) / 1e6


def main():
    search = "--search" in sys.argv
    accounts = [a for a in sys.argv[1:] if a != "--search"] or (["scale1000", "scalebig"] if search else list(ROOMS))
    if any(a not in ROOMS for a in accounts):
        raise SystemExit(__doc__)
    passwords = json.load(open(os.path.join(DIR, "passwords.json")))
    proxy = subprocess.Popen([os.path.join(ROOT, "infra/test/fault_proxy.py"), "--listen", str(PROXY), "--control", str(CONTROL),
                              "--upstream", f"localhost:{PORT}"], stdout=subprocess.DEVNULL)
    results = []
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{CONTROL}/rules", timeout=1).read()
                break
            except OSError:
                time.sleep(0.1)
        for account in accounts:
            env = dict(os.environ, **{"TEST_RUNNER_" + key: value for key, value in {
                "HALO_SCALE_SERVER": f"http://localhost:{PROXY}", "HALO_SCALE_CONTROL": f"http://localhost:{CONTROL}",
                "HALO_SCALE_SEARCH": os.environ.get("HALO_SCALE_SEARCH", "1"), "HALO_SCALE_DIRECT": f"http://localhost:{PORT}", "HALO_SCALE_USER": account, "HALO_SCALE_PASSWORD": passwords[account],
                "HALO_SCALE_PROBE_PASSWORD": passwords["scaleprobe"], "HALO_SCALE_ROOMS": str(ROOMS[account]), **({"HALO_SCALE_HISTORY": "1"} if search else {})}.items()})
            run = subprocess.run(["xcodebuild", "-scheme", "HaloApple-Package", "-destination", f"platform=iOS Simulator,name={os.environ.get('HALO_SIM', 'iPhone 17')}",
                                  f"-only-testing:HaloMatrixAdapterTests/ScaleMeasurements", "test"],
                                 cwd=os.path.join(ROOT, "ios/Packages/HaloApple"), env=env, capture_output=True, text=True)
            found = re.search(r"SCALE (\{.*\})", run.stdout)
            if not found:
                print("\n".join(l for l in run.stdout.splitlines() if l.startswith("PROGRESS")), file=sys.stderr)
                print("\n".join(l for l in run.stdout.splitlines() if "✘" in l or "error:" in l)[-2000:], file=sys.stderr)
                raise SystemExit(f"{account}: no result (exit {run.returncode})")
            results.append(json.loads(found.group(1)))
            if search:
                print("\n".join(l for l in run.stdout.splitlines() if l.startswith("PROGRESS")))
                print(json.dumps({account: results[-1]}, indent=1), "" if run.returncode == 0 else "\n" + "\n".join(l for l in run.stdout.splitlines() if "✘" in l)[-1500:], flush=True)
            print(f"measured {account}", file=sys.stderr, flush=True)
    finally:
        proxy.terminate()
    out = os.path.join(DIR, time.strftime("results-%Y%m%d-%H%M%S.json"))
    json.dump(results, open(out, "w"), indent=1)
    if search:
        return
    rows = [
        ("First sync → all rooms in the list", lambda r: f"{r['firstListSeconds']:.1f} s"),
        ("First sync, response and traffic", lambda r: "{} requests, {:.1f} MB".format(*traffic(r["firstTraffic"], "/sync"))),
        ("All traffic until settled (20 s later)", lambda r: "{} requests, {:.1f} MB".format(*traffic(r["settledTraffic"]))),
        ("Peak memory, first sync (before)", lambda r: f"{r['firstPeakMB']:.0f} MB ({r['memoryBeforeMB']:.0f})"),
        ("Memory settled", lambda r: f"{r['settledMB']:.0f} MB"),
        ("Store on disk", lambda r: f"{r['storeMB']:.0f} MB"),
        ("Idle, per minute", lambda r: f"{r['idleCPUSecondsPerMinute']:.2f} s CPU, " + "{} requests, {:.3f} MB".format(*traffic(r["idleTraffic"]))),
        ("Threads, after the idle minute", lambda r: str(r["threads"])),
        ("Live message → in the list", lambda r: f"{r['liveMessageSeconds']:.2f} s" if "liveMessageSeconds" in r else "—"),
        ("Restart: session restored", lambda r: f"{r['restoreSeconds']:.2f} s"),
        ("Restart: cached list complete", lambda r: f"{r['cachedListSeconds']:.2f} s"),
        ("Catch-up after a day", lambda r: f"{r['catchUpSeconds']:.1f} s ({r['catchUpRooms']} rooms), " + "{} requests, {:.1f} MB".format(*traffic(r["catchUpTraffic"]))),
        ("Search: listening to every room", lambda r: f"{r['listenSeconds']:.2f} s" if "catchUpFound" in r else "—"),
        ("Search: caught-up messages in the index", lambda r: f"{r['catchUpIndexedSeconds']:.1f} s, {r['catchUpFound']} found" if "catchUpFound" in r else "—"),
        ("Peak memory, catch-up", lambda r: f"{r['catchUpPeakMB']:.0f} MB"),
    ]
    print("| Measurement | " + " | ".join(r["account"] for r in results) + " |\n|---|" + "---|" * len(results))
    for title, value in rows:
        print(f"| {title} | " + " | ".join(value(r) for r in results) + " |")
    print(f"raw: {out}", file=sys.stderr)


main()
