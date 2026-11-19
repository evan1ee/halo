#!/usr/bin/env python3
"""Session Handoff Rule checks (AGENTS.md §18, D67).

Modes:
  check_handoff.py structure            HANDOFF.md exists, has every required section, a "Last updated"
                                        date, a Next Session Prompt in a ```text block, and stays short.
  check_handoff.py commit <sha>         <sha> (the tip of a push or pull request) modifies HANDOFF.md.
  check_handoff.py pre-push <remote>    Git pre-push hook: reads the refs being pushed from stdin and
                                        requires the tip commit of every pushed branch to modify HANDOFF.md.

Exit code 0 = rule satisfied, 1 = violated (the reason is printed).
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HANDOFF = "HANDOFF.md"
REQUIRED_SECTIONS = [
    "1. Current status",
    "2. Completed work",
    "3. Key decisions",
    "4. Modified files",
    "5. Outstanding issues",
    "6. Next steps",
    "7. Next Session Prompt",
]
MAX_LINES = 250          # the handoff must stay cheaper to read than re-deriving the context
MAX_PROMPT_LINES = 60
ZERO = "0" * 40


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def structure() -> list[str]:
    path = ROOT / HANDOFF
    if not path.exists():
        return [f"{HANDOFF} is missing (AGENTS.md §18)"]
    text = path.read_text()
    problems = []
    headings = re.findall(r"^## (.+)$", text, flags=re.M)
    for section in REQUIRED_SECTIONS:
        if not any(h.startswith(section) for h in headings):
            problems.append(f"{HANDOFF}: missing section '## {section}'")
    if not re.search(r"^Last updated: \d{4}-\d{2}-\d{2}\b", text, flags=re.M):
        problems.append(f"{HANDOFF}: missing 'Last updated: YYYY-MM-DD' line")
    prompt = text.split("## 7. Next Session Prompt", 1)[-1]
    block = re.search(r"```text\n(.*?)\n```", prompt, flags=re.S)
    if not block:
        problems.append(f"{HANDOFF}: the Next Session Prompt must be a ```text block in section 7")
    elif len(block.group(1).splitlines()) > MAX_PROMPT_LINES:
        problems.append(f"{HANDOFF}: Next Session Prompt has more than {MAX_PROMPT_LINES} lines — link to sections instead")
    if len(text.splitlines()) > MAX_LINES:
        problems.append(f"{HANDOFF}: longer than {MAX_LINES} lines — move history to git log and link to docs")
    return problems


def files_changed_by(sha: str) -> set[str]:
    parents = git("rev-list", "--parents", "-n", "1", sha).split()[1:]
    if not parents:  # root commit
        return set(git("show", "--name-only", "--format=", sha).split())
    return set(git("diff", "--name-only", parents[0], sha).split())


def commit(sha: str) -> list[str]:
    if HANDOFF not in files_changed_by(sha):
        short = git("rev-parse", "--short", sha).strip()
        return [f"tip commit {short} doesn't update {HANDOFF}: every push ends with a commit that includes the "
                f"updated handoff (AGENTS.md §18). Update {HANDOFF} and amend or add it to your last commit."]
    return []


def pre_push(remote: str, stdin: str) -> list[str]:
    problems = []
    for line in stdin.splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        local_ref, local_sha, _remote_ref, remote_sha = parts
        if local_sha == ZERO or not local_ref.startswith("refs/heads/"):
            continue  # branch deletion or tag push
        new_commits = git("rev-list", local_sha, "--not", f"--remotes={remote}").split()
        if remote_sha != ZERO and not new_commits:
            continue  # nothing new (e.g. re-push)
        problems += commit(local_sha)
    return problems + structure()


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in ("structure", "commit", "pre-push"):
        print(__doc__)
        return 2
    mode = sys.argv[1]
    if mode == "structure":
        problems = structure()
    elif mode == "commit":
        problems = commit(sys.argv[2]) + structure()
    else:
        problems = pre_push(sys.argv[2] if len(sys.argv) > 2 else "origin", sys.stdin.read())
    for p in problems:
        print(f"handoff: {p}")
    if not problems:
        print("handoff: rule satisfied")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
