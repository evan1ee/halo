#!/usr/bin/env bash
# Validate the documentation tree (Phase 0+). Usage: scripts/validate-docs.sh
set -euo pipefail
exec python3 -I "$(dirname "$0")/validate_docs.py"
