#!/usr/bin/env python3
"""Module boundary and forbidden-pattern checks for Halo's Swift packages.

Enforces the import rules of docs/architecture/MODULE_BOUNDARIES.md §2 and the source patterns
forbidden by AGENTS.md §17 that a grep can find reliably. The compiler already rejects imports a
package doesn't declare; this script also catches a manifest that declares a forbidden dependency.

Rules for the adapter's public API (no upstream type in a public/package signature) are added with
HaloMatrixAdapter in M0b, when there is an adapter to check.

Usage: scripts/check-boundaries.sh [repository root]. Exit code 0 = clean, 1 = violations (printed).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
PACKAGES = ROOT / "ios" / "Packages"
FEATURES = PACKAGES / "Features"

APPLE_UI = {"SwiftUI", "UIKit", "UserNotifications"}
INFRASTRUCTURE = {"HaloMatrixAdapter", "HaloPersistence", "HaloPlatform"}
HALO_MODULES = {"HaloFoundation", "HaloDomain", "HaloApplication", "HaloDesignSystem", "HaloBotRendering",
                "HaloTestSupport"} | INFRASTRUCTURE

# module → (forbidden imports, reason). Feature* modules are handled separately.
RULES: dict[str, tuple[set[str], str]] = {
    "HaloFoundation": (HALO_MODULES - {"HaloFoundation"} | APPLE_UI | {"GRDB", "MatrixRustSDK"},
                       "HaloFoundation is the base and imports nothing from Halo"),
    "HaloDomain": (HALO_MODULES - {"HaloFoundation", "HaloDomain"} | APPLE_UI | {"GRDB", "MatrixRustSDK"},
                   "HaloDomain imports only HaloFoundation"),
    "HaloApplication": (INFRASTRUCTURE | APPLE_UI | {"HaloDesignSystem", "HaloBotRendering", "GRDB", "MatrixRustSDK"},
                        "HaloApplication uses ports, not infrastructure or UI frameworks"),
    "HaloTestSupport": ({"HaloApplication"} | INFRASTRUCTURE | {"MatrixRustSDK"},
                        "HaloTestSupport depends only on HaloDomain and HaloFoundation"),
    "HaloPersistence": ({"MatrixRustSDK", "HaloApplication"} | APPLE_UI, "HaloPersistence implements ports only"),
    "HaloPlatform": ({"MatrixRustSDK", "HaloApplication", "GRDB"}, "HaloPlatform implements ports only"),
    "HaloDesignSystem": (HALO_MODULES - {"HaloFoundation", "HaloDesignSystem"} | {"MatrixRustSDK", "GRDB"},
                         "HaloDesignSystem has no business logic"),
    "HaloBotRendering": (HALO_MODULES - {"HaloFoundation", "HaloDomain", "HaloDesignSystem", "HaloBotRendering"}
                         | {"MatrixRustSDK", "GRDB"}, "HaloBotRendering depends on HaloDomain + HaloDesignSystem (D19)"),
}

IMPORT_RE = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][\w]*)", re.M)
PRINT_RE = re.compile(r"(?<![\w.])print\(")
TRY_BANG_RE = re.compile(r"\btry!")

violations: list[str] = []


def strip_comments_and_strings(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    source = re.sub(r'"""(?:.|\n)*?"""', '""', source)
    source = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', source)
    return re.sub(r"//[^\n]*", "", source)


def module_of(path: Path) -> tuple[str, bool] | None:
    """(module name, is test code) for a Swift file under ios/Packages, else None."""
    rel = path.relative_to(PACKAGES).parts
    if rel[0] == "Features":
        if len(rel) < 4:
            return None
        package, kind = rel[1], rel[2]
    else:
        package, kind = rel[0], rel[1]
    if kind not in ("Sources", "Tests"):
        return None
    return package, kind == "Tests"


def check_file(path: Path) -> None:
    info = module_of(path)
    if info is None:
        return
    module, is_test = info
    code = strip_comments_and_strings(path.read_text())
    imports = set(IMPORT_RE.findall(code))
    where = path.relative_to(ROOT)

    if "MatrixRustSDK" in imports and module != "HaloMatrixAdapter":
        violations.append(f"{where}: imports MatrixRustSDK outside HaloMatrixAdapter (AGENTS.md §4.3)")
    if not is_test:
        if module in RULES:
            forbidden, reason = RULES[module]
            for name in sorted(imports & forbidden):
                violations.append(f"{where}: imports {name} — {reason}")
        if module.startswith("Feature"):
            for name in sorted(imports & INFRASTRUCTURE):
                violations.append(f"{where}: feature imports {name} — features use HaloApplication, not infrastructure")
            for name in sorted(i for i in imports if i.startswith("Feature") and i != module):
                violations.append(f"{where}: feature imports another feature ({name}) — navigate through HaloApplication routes")
            if re.search(r"\bReadStatePolicy\b", code):
                violations.append(f"{where}: feature calls ReadStatePolicy directly — consume ReadStateCoordinator instead (R-05, AGENTS.md §4.2)")
        if PRINT_RE.search(code):
            violations.append(f"{where}: print( in production code — use HaloLog (AGENTS.md §17)")
        if TRY_BANG_RE.search(code):
            violations.append(f"{where}: try! in production code (AGENTS.md §17)")
    elif module == "HaloTestSupport" and "HaloApplication" in imports:
        violations.append(f"{where}: HaloTestSupport must not import HaloApplication (package cycle)")


def check_manifests() -> None:
    """A package manifest must not declare a dependency its module may not import."""
    for manifest in sorted(PACKAGES.glob("**/Package.swift")):
        if ".build" in manifest.parts:
            continue
        module = manifest.parent.name
        text = manifest.read_text()
        declared = set(re.findall(r'\.package\(\s*path:\s*"[^"]*/([^"/]+)"', text))
        declared |= {m for m in ("MatrixRustSDK", "GRDB") if m in text}
        forbidden = RULES.get(module, (set(), ""))[0]
        if module.startswith("Feature"):
            forbidden = INFRASTRUCTURE | {"MatrixRustSDK", "GRDB"}
        # Test-only dependencies are allowed (e.g. HaloApplication tests use HaloTestSupport).
        test_only = set(re.findall(r'\.testTarget\([^)]*?dependencies:\s*\[([^\]]*)\]', text, flags=re.S))
        test_names = {n for block in test_only for n in re.findall(r'"(\w+)"', block)}
        for name in sorted((declared & forbidden) - test_names):
            violations.append(f"{manifest.relative_to(ROOT)}: declares {name}, which {module} may not depend on")


PUBLIC_DECL_RE = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|open)\b[^\n{=]*", re.M)
SDK_TYPE_RE = re.compile(r"^(?:public|open)\s+(?:indirect\s+)?(?:final\s+)?(?:class|struct|enum|protocol|typealias)\s+([A-Z]\w*)", re.M)
ADAPTER = PACKAGES / "HaloMatrixAdapter"
SDK_SOURCES = ADAPTER / ".build" / "checkouts" / "matrix-rust-components-swift" / "Sources" / "MatrixRustSDK"
adapter_api_skipped = False


def check_adapter_public_api() -> None:
    """No upstream type may appear in a public signature of HaloMatrixAdapter (AGENTS.md §4.3, §17).

    The upstream type names are read from the resolved SDK checkout, so the rule stays exact when the SDK
    is bumped. Without a checkout (e.g. Linux CI) it can't run, and says so."""
    global adapter_api_skipped
    if not SDK_SOURCES.exists():
        adapter_api_skipped = True
        return
    names = {n for f in SDK_SOURCES.glob("*.swift") for n in SDK_TYPE_RE.findall(f.read_text())}
    # Halo domain types that share a name with an upstream type are fine only when module-qualified.
    for path in sorted((ADAPTER / "Sources").rglob("*.swift")):
        code = strip_comments_and_strings(path.read_text())
        for decl in PUBLIC_DECL_RE.findall(code):
            tokens = set(re.findall(r"(?<![\w.])([A-Z]\w*)", decl))
            for name in sorted(tokens & names):
                violations.append(f"{path.relative_to(ROOT)}: public signature mentions upstream type {name}: `{decl.strip()}`")


def main() -> int:
    if not PACKAGES.exists():
        print("check-boundaries: no ios/Packages yet — nothing to check")
        return 0
    for path in sorted(PACKAGES.rglob("*.swift")):
        if ".build" in path.parts or path.name == "Package.swift":
            continue
        check_file(path)
    check_manifests()
    check_adapter_public_api()
    if violations:
        print(f"check-boundaries: {len(violations)} violation(s)")
        for v in violations:
            print(f"  - {v}")
        return 1
    if adapter_api_skipped:
        print("check-boundaries: SKIPPED adapter public-API rule (no SDK checkout; run after `swift package resolve` in the adapter)")
    print("check-boundaries: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
