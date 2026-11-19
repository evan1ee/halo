#!/usr/bin/env python3
"""Validate the Halo documentation tree.

Checks: required files, feature-spec and ADR sections, relative links, and that every
referenced ID (Dnn, ADR-nnnn, F-*, V-*, Q-*, AC-*, S-scenarios) is defined where it must be.
Exit code 0 = all checks passed, 1 = failures (printed).
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"

REQUIRED = [
    "AGENTS.md", "README.md", "CONTRIBUTING.md", "LICENSE", ".gitignore", "CLAUDE.md",
    "docs/README.md", "docs/PRODUCT_VISION.md", "docs/REQUIREMENTS.md", "docs/ROADMAP.md",
    "docs/DECISION_LOG.md", "docs/SOURCES.md", "docs/GLOSSARY.md", "docs/OPEN_QUESTIONS.md",
    "docs/RISK_REGISTER.md", "docs/PHASE0_REPORT.md",
    "docs/architecture/OVERVIEW.md", "docs/architecture/SYSTEM_DESIGN.md",
    "docs/architecture/MODULE_BOUNDARIES.md", "docs/architecture/DATA_FLOW.md",
    "docs/architecture/CONCURRENCY.md", "docs/architecture/ERROR_HANDLING.md",
    "docs/architecture/BACKGROUND_EXECUTION.md", "docs/architecture/LOGGING_AND_DIAGNOSTICS.md",
    "docs/architecture/ARCHITECTURE_DECISIONS.md",
    "docs/matrix/SDK_INTEGRATION.md", "docs/matrix/RUST_FFI.md", "docs/matrix/PORTS_CONTRACT.md",
    "docs/matrix/SYNC_ENGINE.md", "docs/matrix/UNREAD_STATE.md", "docs/matrix/READ_RECEIPTS.md",
    "docs/matrix/PUSH_NOTIFICATIONS.md", "docs/matrix/MEDIA.md",
    "docs/features/_TEMPLATE.md", "docs/features/AUTHENTICATION.md",
    "docs/features/ENCRYPTION_AND_DEVICES.md", "docs/features/ROOM_LIST.md",
    "docs/features/TIMELINE.md", "docs/features/MESSAGING.md", "docs/features/MEDIA_ATTACHMENTS.md",
    "docs/features/NOTIFICATIONS.md", "docs/features/ROOM_MANAGEMENT.md",
    "docs/features/USER_PROFILES.md", "docs/features/SETTINGS.md", "docs/features/STICKERS.md",
    "docs/features/BOT_MESSAGES.md", "docs/features/BOT_ACTIVITY.md",
    "docs/design/DESIGN_SYSTEM.md", "docs/design/NAVIGATION.md", "docs/design/SCREEN_SPECIFICATIONS.md",
    "docs/data/DATA_MODELS.md", "docs/data/PERSISTENCE.md", "docs/data/MIGRATIONS.md",
    "docs/security/SECURITY.md", "docs/security/PRIVACY.md", "docs/security/LICENSE_COMPLIANCE.md",
    "docs/security/DEPENDENCY_INVENTORY.md", "docs/security/inventory/rust-deps-matrix-sdk-ffi.csv",
    "docs/testing/TEST_STRATEGY.md", "docs/testing/UNREAD_REGRESSION_TESTS.md",
    "docs/testing/INTEGRATION_TESTS.md",
    "docs/development/DEVELOPMENT_SETUP.md", "docs/development/CODE_CONVENTIONS.md",
    "docs/development/BUILD_AND_RELEASE.md", "docs/development/CI_CD.md",
    "docs/adr/README.md", "docs/adr/TEMPLATE.md",
]

# Feature specs: each required section is matched by a regex on "## " headings.
FEATURE_SECTIONS = {
    "purpose": r"purpose",
    "user stories": r"user stories",
    "functional requirements": r"functional requirements",
    "non-functional requirements": r"non-functional",
    "user flows": r"flows?",
    "state transitions": r"state",
    "data models": r"data models?",
    "API boundaries": r"api boundar",
    "error scenarios": r"error",
    "edge cases": r"edge cases",
    "acceptance criteria": r"acceptance criteria",
    "test requirements": r"test requirements",
}
ADR_SECTIONS = ["Context", "Problem", "Considered alternatives", "Decision", "Rationale",
                "Trade-offs", "Consequences"]
MIN_ADRS = 14

failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


def md_files() -> list[pathlib.Path]:
    files = [p for p in DOCS.rglob("*.md")]
    files += [ROOT / n for n in ("AGENTS.md", "README.md", "CONTRIBUTING.md", "CLAUDE.md")]
    return [f for f in files if f.exists()]


def text_without_code(text: str) -> str:
    return re.sub(r"```.*?```", "", text, flags=re.S)


def check_required() -> None:
    for rel in REQUIRED:
        if not (ROOT / rel).exists():
            fail(f"missing required file: {rel}")


def check_feature_specs() -> None:
    for spec in sorted((DOCS / "features").glob("*.md")):
        if spec.name.startswith("_"):
            continue
        headings = [h.lower() for h in re.findall(r"^## (.+)$", spec.read_text(), flags=re.M)]
        for name, pattern in FEATURE_SECTIONS.items():
            if not any(re.search(pattern, h) for h in headings):
                fail(f"{spec.relative_to(ROOT)}: missing section '{name}'")


def check_adrs() -> None:
    adrs = sorted(p for p in (DOCS / "adr").glob("[0-9][0-9][0-9][0-9]-*.md"))
    if len(adrs) < MIN_ADRS:
        fail(f"expected at least {MIN_ADRS} ADRs, found {len(adrs)}")
    index = (DOCS / "adr" / "README.md").read_text()
    for adr in adrs:
        body = adr.read_text()
        for section in ADR_SECTIONS:
            if not re.search(rf"^## {re.escape(section)}\b", body, flags=re.M):
                fail(f"{adr.relative_to(ROOT)}: missing section '{section}'")
        if "**Status:**" not in body:
            fail(f"{adr.relative_to(ROOT)}: missing Status")
        if adr.name not in index:
            fail(f"docs/adr/README.md: ADR {adr.name} not indexed")


LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")


def check_links() -> None:
    for f in md_files():
        for target in LINK_RE.findall(text_without_code(f.read_text())):
            if re.match(r"^[a-z]+:", target) or target.startswith("#"):
                continue
            path = target.split("#", 1)[0]
            if not path:
                continue
            if not (f.parent / path).resolve().exists():
                fail(f"{f.relative_to(ROOT)}: broken link -> {target}")


def collect(pattern: str, files: list[pathlib.Path]) -> set[str]:
    found: set[str] = set()
    for f in files:
        found.update(re.findall(pattern, f.read_text()))
    return found


def check_ids() -> None:
    files = md_files()
    decision_log = (DOCS / "DECISION_LOG.md").read_text()
    sources = (DOCS / "SOURCES.md").read_text()
    open_q = (DOCS / "OPEN_QUESTIONS.md").read_text()
    requirements = (DOCS / "REQUIREMENTS.md").read_text()

    defined_d = set(re.findall(r"^\| (D\d+) \|", decision_log, flags=re.M))
    for d in sorted(collect(r"\bD\d{1,2}\b", files)):
        if d not in defined_d:
            fail(f"decision {d} referenced but not defined in DECISION_LOG.md")

    adr_numbers = {p.name[:4] for p in (DOCS / "adr").glob("[0-9][0-9][0-9][0-9]-*.md")}
    for a in sorted(collect(r"\bADR-(\d{4})\b", files)):
        if a not in adr_numbers and a != "NNNN":
            fail(f"ADR-{a} referenced but no file docs/adr/{a}-*.md")

    defined_f = set(re.findall(r"^- (F-[A-Z]+-\d+)\b", sources, flags=re.M))
    for fid in sorted(collect(r"\bF-(?:LIC|FFI|SDK|SPEC|BOT)-\d+\b", files)):
        if fid not in defined_f:
            fail(f"fact {fid} referenced but not defined in SOURCES.md")

    defined_vq = set(re.findall(r"^\| ((?:V|Q)-[A-Z0-9-]+) \|", open_q, flags=re.M))
    family = {re.sub(r"-\d+$", "", x) for x in defined_vq}
    for vq in sorted(collect(r"\b(?:V|Q)-[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)*\b", files)):
        if vq not in defined_vq and vq not in family:
            fail(f"item {vq} referenced but not defined in OPEN_QUESTIONS.md")

    # An acceptance criterion is *defined* only by a list item that starts with its ID.
    ac_def = re.compile(r"^- (?:\*\*)?(AC-[A-Z]+-?\d+)(?:\*\*)?\s", flags=re.M)
    defined_ac = set(ac_def.findall(requirements))
    for f in (DOCS / "features").glob("*.md"):
        defined_ac.update(ac_def.findall(f.read_text()))
    for ac in sorted(collect(r"\bAC-[A-Z]+-?\d+\b", files)):
        if ac not in defined_ac:
            fail(f"acceptance criterion {ac} referenced but never defined")


def check_scenarios() -> None:
    files = md_files()
    catalogue = (DOCS / "testing" / "UNREAD_REGRESSION_TESTS.md").read_text() + \
        (DOCS / "testing" / "INTEGRATION_TESTS.md").read_text()
    defined = set(re.findall(r"\b(S\d{2}|S-[A-Z0-9]+-\d+)\b", catalogue))
    for sid in sorted(collect(r"\b(S\d{2}|S-[A-Z0-9]+-\d+)\b", files)):
        if sid not in defined:
            fail(f"scenario {sid} referenced but not in the testing catalogues")


def check_labels_and_stale() -> None:
    stale = ["docs/decisions.md", "01-PRD.md", "02-Technical-Architecture.md", "03-Licensing",
             "05-Unread-Notification-Design.md"]
    for f in md_files():
        body = f.read_text()
        for s in stale:
            if s in body:
                fail(f"{f.relative_to(ROOT)}: reference to removed document '{s}'")
        if body.count("```") % 2:
            fail(f"{f.relative_to(ROOT)}: unbalanced code fences")
        for label in re.findall(r"\*\*\[([A-Z]+)", body):
            if label not in {"VERIFIED", "DECISION", "ASSUMPTION", "OPEN"}:
                fail(f"{f.relative_to(ROOT)}: unknown statement label [{label}]")


def main() -> int:
    check_required()
    check_feature_specs()
    check_adrs()
    check_links()
    check_ids()
    check_scenarios()
    check_labels_and_stale()
    if failures:
        print(f"validate-docs: {len(failures)} problem(s)")
        for msg in failures:
            print(f"  - {msg}")
        return 1
    print("validate-docs: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
