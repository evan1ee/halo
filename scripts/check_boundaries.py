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
    if len(rel) < 4:
        return None
    # Two-manifest layout (ADR-0022): ios/Packages/<Package>/{Sources,Tests}/<Target>/...
    kind, target = rel[1], rel[2]
    if kind not in ("Sources", "Tests"):
        return None
    is_test = kind == "Tests"
    module = target[:-5] if is_test and target.endswith("Tests") else target
    return module, is_test


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


TARGET_BLOCK_RE = re.compile(
    r'\.target\(\s*name:\s*"(\w+)"(.*?)(?=\n\s*\.(?:target|testTarget)\(|\n\s*\]|\Z)',
    re.S,
)


def check_manifests() -> None:
    """A manifest target must not declare a dependency its module may not import."""
    for manifest in sorted(PACKAGES.glob("*/Package.swift")):
        if ".build" in manifest.parts:
            continue
        text = manifest.read_text()
        for module, body in TARGET_BLOCK_RE.findall(text):
            deps_match = re.search(r"dependencies:\s*\[([^\]]*)\]", body, flags=re.S)
            if not deps_match:
                continue
            deps_block = deps_match.group(1)
            declared = set(re.findall(r'\.product\(\s*name:\s*"(\w+)"', deps_block))
            declared |= set(re.findall(r'(?<!name:\s)(?<!package:\s)"(\w+)"', deps_block))
            # Remove package names that appeared in `package: "HaloCore"` etc.
            pkg_names = set(re.findall(r'package:\s*"([^"]+)"', deps_block))
            declared -= pkg_names
            forbidden = RULES.get(module, (set(), ""))[0]
            if module.startswith("Feature"):
                forbidden = INFRASTRUCTURE | {"MatrixRustSDK", "GRDB"}
                for other in sorted(d for d in declared if d.startswith("Feature") and d != module):
                    violations.append(
                        f"{manifest.relative_to(ROOT)}: target {module} declares feature dependency {other}"
                    )
            for name in sorted(declared & forbidden):
                violations.append(
                    f"{manifest.relative_to(ROOT)}: target {module} declares {name}, which {module} may not depend on"
                )


PUBLIC_DECL_RE = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|open)\b[^\n{=]*", re.M)
PUBLIC_TYPE_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|open)\s+"
    r"(?:(?:indirect|final|nonisolated|distributed)\s+)*"
    r"(?:class|struct|enum|protocol|actor|typealias)\s+([A-Z]\w*)",
    re.M,
)
FEATURE_NAME_RE = re.compile(r"^Feature[A-Z][A-Za-z0-9]*$")
LAYER_NAME_RE = re.compile(r"^Halo[A-Z][A-Za-z0-9]*$")
SDK_TYPE_RE = re.compile(r"^(?:public|open)\s+(?:indirect\s+)?(?:final\s+)?(?:class|struct|enum|protocol|typealias)\s+([A-Z]\w*)", re.M)
APPLE_PKG = PACKAGES / "HaloApple"
ADAPTER_SRC = APPLE_PKG / "Sources" / "HaloMatrixAdapter"
SDK_SOURCES = APPLE_PKG / ".build" / "checkouts" / "matrix-rust-components-swift" / "Sources" / "MatrixRustSDK"
adapter_api_skipped = False


def check_module_naming() -> None:
    """Enforce MODULE_BOUNDARIES.md §1 'Module naming' (D86)."""
    modules: list[tuple[str, Path]] = []
    for pkg in sorted(PACKAGES.iterdir()):
        if not pkg.is_dir() or pkg.name.startswith("."):
            continue
        if not LAYER_NAME_RE.match(pkg.name):
            violations.append(
                f"{pkg.relative_to(ROOT)}: package '{pkg.name}' must match Halo<Layer> "
                "(MODULE_BOUNDARIES.md §1)"
            )
        sources_dir = pkg / "Sources"
        if not sources_dir.is_dir():
            continue
        for target in sorted(sources_dir.iterdir()):
            if not target.is_dir() or target.name.startswith("."):
                continue
            modules.append((target.name, target))
            if target.name.startswith("Feature"):
                if not FEATURE_NAME_RE.match(target.name):
                    violations.append(
                        f"{target.relative_to(ROOT)}: feature module '{target.name}' must match Feature<Area> "
                        "(MODULE_BOUNDARIES.md §1)"
                    )
            elif not LAYER_NAME_RE.match(target.name):
                violations.append(
                    f"{target.relative_to(ROOT)}: module '{target.name}' must match Halo<Layer> or Feature<Area> "
                    "(MODULE_BOUNDARIES.md §1)"
                )

    core_types: dict[str, Path] = {}
    for core_mod in ("HaloDomain", "HaloApplication"):
        src_dir = PACKAGES / "HaloCore" / "Sources" / core_mod
        if not src_dir.exists():
            continue
        for swift_file in sorted(src_dir.rglob("*.swift")):
            code = strip_comments_and_strings(swift_file.read_text())
            for type_name in PUBLIC_TYPE_RE.findall(code):
                core_types.setdefault(type_name, swift_file)

    for mod_name, mod_path in modules:
        if mod_name in core_types:
            decl_where = core_types[mod_name].relative_to(ROOT)
            violations.append(
                f"{mod_path.relative_to(ROOT)}: module name '{mod_name}' collides with public type in "
                f"{decl_where} (MODULE_BOUNDARIES.md §1)"
            )


def check_adapter_public_api() -> None:
    """No upstream type may appear in a public signature of HaloMatrixAdapter (AGENTS.md §4.3, §17).

    The upstream type names are read from the resolved SDK checkout, so the rule stays exact when the SDK
    is bumped. Without a checkout (e.g. Linux CI) it can't run, and says so."""
    global adapter_api_skipped
    if not SDK_SOURCES.exists() or not ADAPTER_SRC.exists():
        adapter_api_skipped = True
        return
    names = {n for f in SDK_SOURCES.glob("*.swift") for n in SDK_TYPE_RE.findall(f.read_text())}
    # Halo domain types that share a name with an upstream type are fine only when module-qualified.
    for path in sorted(ADAPTER_SRC.rglob("*.swift")):
        code = strip_comments_and_strings(path.read_text())
        for decl in PUBLIC_DECL_RE.findall(code):
            tokens = set(re.findall(r"(?<![\w.])([A-Z]\w*)", decl))
            for name in sorted(tokens & names):
                violations.append(f"{path.relative_to(ROOT)}: public signature mentions upstream type {name}: `{decl.strip()}`")


# Composition roots are wiring (AGENTS.md §5, audit F-02): behaviour lives in a package where it is unit-tested. The only reference
# types a root may declare are its object graph, the OS entry points it must subclass, and `…Box` holders that hand a reference
# across isolation. Anything else (a coordinator, an engine, a store) belongs in HaloApplication or a feature.
COMPOSITION_ROOTS = ("App", "NotificationService", "ShareExtension", "WidgetExtension")
ROOT_TYPES_ALLOWED = {"AppRoot", "PushDelegate", "BackgroundTaskLease", "NotificationService", "ShareViewController"}
ROOT_TYPE_RE = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:public|private|fileprivate|internal|final)\s+)*(?:class|actor)\s+([A-Z]\w*)", re.M)


def check_composition_roots() -> None:
    for folder in COMPOSITION_ROOTS:
        base = ROOT / "ios" / folder
        if not base.exists():
            continue
        for path in sorted(base.rglob("*.swift")):
            code = strip_comments_and_strings(path.read_text())
            for name in ROOT_TYPE_RE.findall(code):
                if name in ROOT_TYPES_ALLOWED or name.endswith("Box"):
                    continue
                violations.append(
                    f"{path.relative_to(ROOT)}: composition root declares class/actor {name}; move behaviour into "
                    "HaloApplication or a feature (AGENTS.md §5, audit F-02)")


def main() -> int:
    if not PACKAGES.exists():
        print("check-boundaries: no ios/Packages yet — nothing to check")
        return 0
    for path in sorted(PACKAGES.rglob("*.swift")):
        if ".build" in path.parts or path.name == "Package.swift":
            continue
        check_file(path)
    check_module_naming()
    check_manifests()
    check_adapter_public_api()
    check_composition_roots()
    if violations:
        print(f"check-boundaries: {len(violations)} violation(s)")
        for v in violations:
            print(f"  - {v}")
        return 1
    if adapter_api_skipped:
        print("check-boundaries: SKIPPED adapter public-API rule (no SDK checkout; run after `swift package resolve` in ios/Packages/HaloApple)")
    print("check-boundaries: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
