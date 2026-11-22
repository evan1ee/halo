#!/usr/bin/env bash
# Enforces DESIGN_SYSTEM §2–3 (AC-UX-1): no raw system colours or fixed font sizes outside HaloDesignSystem.
# Lines ending with `// design-token:allow` are skipped (only for fixed-size SF Symbols with a written reason).
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import sys
from pathlib import Path

RAW_COLOR_RE = re.compile(
    r'(?:'
    r'Color\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|white|black)\b'
    r'|\.(?:foregroundStyle|foregroundColor|tint|fill|stroke|background)\([^)\n]*\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|white|black)\b'
    r'|colors:\s*\[[^\]]*\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|white|black)\b'
    r')'
)
FIXED_FONT_RE = re.compile(r'\.font\(\s*\.system\(\s*size:')

roots = [Path("ios/App")] + sorted(Path("ios/Packages/HaloApple/Sources").glob("Feature*"))
violations: list[str] = []

for root in roots:
    if not root.exists():
        continue
    for path in sorted(root.rglob("*.swift")):
        for idx, line in enumerate(path.read_text().splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//") or "design-token:allow" in line:
                continue
            if RAW_COLOR_RE.search(line):
                violations.append(f"{path}:{idx}: raw system colour (use HaloColor): {stripped}")
            if FIXED_FONT_RE.search(line):
                violations.append(f"{path}:{idx}: fixed font size (use HaloTypography or Dynamic Type): {stripped}")

if violations:
    print(f"check-design-tokens: {len(violations)} violation(s)")
    for v in violations:
        print(f"  - {v}")
    sys.exit(1)

print("check-design-tokens: all checks passed")
PY
