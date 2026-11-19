#!/usr/bin/env bash
# Module boundary checks (docs/architecture/MODULE_BOUNDARIES.md §2, AGENTS.md §13). Runs in CI (boundaries.yml).
set -euo pipefail
exec python3 "$(dirname "$0")/check_boundaries.py" "$@"
