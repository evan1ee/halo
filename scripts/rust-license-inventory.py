#!/usr/bin/env python3
"""Rust licence inventory and gate for the matrix-sdk-ffi build Halo ships.

Walks the normal + build dependencies of `matrix-sdk-ffi` for `aarch64-apple-ios`, with the feature
set the upstream Swift build uses (`sentry`, docs/SOURCES.md F-LIC-2), and checks every crate's
licence expression against the allowlist in docs/security/LICENSE_COMPLIANCE.md §4.

Usage:
  scripts/rust-license-inventory.py --sdk <matrix-rust-sdk checkout> --write docs/security/inventory/rust-deps-matrix-sdk-ffi.csv
  scripts/rust-license-inventory.py --sdk <checkout> --check docs/security/inventory/rust-deps-matrix-sdk-ffi.csv

--write regenerates the CSV; --check fails if the committed CSV differs from what the checkout
produces. Both fail (exit 1) if any crate's licence isn't allowed. Needs `cargo` and network access
to crates.io (cargo metadata reads the locked dependency manifests).
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import re
import subprocess
import sys
from pathlib import Path

TARGET = "aarch64-apple-ios"
FFI_FEATURES = "sentry"
ROOT_CRATE = "matrix-sdk-ffi"
HEADER = ["crate", "version", "license", "repository", "only_with_sentry_feature"]

# LICENSE_COMPLIANCE.md §4 step 2.
ALLOWED = {
    "MIT", "Apache-2.0", "Apache-2.0 WITH LLVM-exception", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib",
    "Unicode-3.0", "MPL-2.0", "CC0-1.0", "0BSD", "Unlicense", "BSL-1.0", "BlueOak-1.0.0", "MIT-0", "OpenSSL",
}
COPYLEFT = re.compile(r"\b(A?GPL|LGPL|SSPL|BUSL)", re.I)


def cargo_metadata(sdk: Path, features: str | None) -> dict:
    cmd = ["cargo", "metadata", "--format-version", "1", "--locked", "--filter-platform", TARGET,
           "--manifest-path", str(sdk / "bindings" / ROOT_CRATE / "Cargo.toml")]
    if features:
        cmd += ["--features", features]
    return json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout)


def dependency_closure(meta: dict) -> dict[str, dict]:
    """Package id → package: the FFI crate itself and every crate reachable from it via normal/build edges."""
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    root = next(pid for pid, p in packages.items() if p["name"] == ROOT_CRATE)
    seen, stack = {root}, [root]
    while stack:
        for dep in nodes[stack.pop()]["deps"]:
            if any(k["kind"] in (None, "build") for k in dep["dep_kinds"]) and dep["pkg"] not in seen:
                seen.add(dep["pkg"])
                stack.append(dep["pkg"])
    return {pid: packages[pid] for pid in seen}


def tokenize(expression: str) -> list[str]:
    # Legacy "A/B" means "A OR B"; "MPL-2.0+" means that version or later.
    expression = expression.replace("/", " OR ").replace("(", " ( ").replace(")", " ) ")
    return expression.split()


def satisfiable(expression: str) -> bool:
    """True if the SPDX expression can be satisfied using only allowed licences."""
    tokens = tokenize(expression)
    pos = 0

    def parse_or() -> bool:
        nonlocal pos
        result = parse_and()
        while pos < len(tokens) and tokens[pos] == "OR":
            pos += 1
            result = parse_and() or result
        return result

    def parse_and() -> bool:
        nonlocal pos
        result = parse_atom()
        while pos < len(tokens) and tokens[pos] == "AND":
            pos += 1
            result = parse_atom() and result
        return result

    def parse_atom() -> bool:
        nonlocal pos
        if tokens[pos] == "(":
            pos += 1
            result = parse_or()
            pos += 1  # ")"
            return result
        licence = tokens[pos].rstrip("+")
        pos += 1
        if pos + 1 < len(tokens) and tokens[pos] == "WITH":
            licence = f"{licence} WITH {tokens[pos + 1]}"
            pos += 2
        return licence in ALLOWED

    try:
        ok = parse_or()
        return ok and pos == len(tokens)
    except IndexError:
        return False


def inventory(sdk: Path) -> list[list[str]]:
    with_sentry = dependency_closure(cargo_metadata(sdk, FFI_FEATURES))
    without = {(p["name"], p["version"]) for p in dependency_closure(cargo_metadata(sdk, None)).values()}
    rows = []
    for p in with_sentry.values():
        rows.append([p["name"], p["version"], p.get("license") or "", p.get("repository") or "",
                     "no" if (p["name"], p["version"]) in without else "yes"])
    return sorted(rows, key=lambda r: (r[0], r[1]))


def render(rows: list[list[str]]) -> str:
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(HEADER)
    writer.writerows(rows)
    return out.getvalue()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sdk", required=True, type=Path, help="matrix-rust-sdk checkout at the shipped commit")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", type=Path)
    mode.add_argument("--check", type=Path)
    args = parser.parse_args()

    rows = inventory(args.sdk)
    problems = []
    for name, version, licence, _, _ in rows:
        if not licence:
            problems.append(f"{name} {version}: no SPDX licence in Cargo.toml (manual review needed)")
        elif not satisfiable(licence):
            problems.append(f"{name} {version}: '{licence}' is not satisfiable with the allowlist")
        elif COPYLEFT.search(licence):
            print(f"note: {name} {version}: '{licence}' mentions a copyleft licence (satisfied by an allowed alternative)")

    text = render(rows)
    sentry_only = sum(1 for r in rows if r[4] == "yes")
    print(f"{len(rows)} crates ({len(rows) - sentry_only} without the sentry feature, {sentry_only} only with it)")
    if args.write:
        args.write.write_text(text)
        print(f"wrote {args.write}")
    else:
        committed = args.check.read_text()
        if committed != text:
            old = {tuple(r) for r in csv.reader(io.StringIO(committed))}
            new = {tuple(r) for r in csv.reader(io.StringIO(text))}
            for r in sorted(old - new):
                print("- " + ",".join(r))
            for r in sorted(new - old):
                print("+ " + ",".join(r))
            problems.append(f"{args.check} doesn't match the checkout; regenerate it with --write and review the diff")
    for p in problems:
        print("FAIL: " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
