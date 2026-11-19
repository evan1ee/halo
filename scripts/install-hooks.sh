#!/usr/bin/env bash
# Use the repository's versioned Git hooks (currently: pre-push → Session Handoff Rule, AGENTS.md §18).
# Run once per clone; AGENTS.md §0 asks every session to run it before its first push.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath scripts/hooks
echo "hooks installed: core.hooksPath = scripts/hooks"
