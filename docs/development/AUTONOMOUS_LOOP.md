# Autonomous development loop

How an AI agent works through the roadmap without asking after every step (founder decision D70, 2026-11-20). It is started
with the `/loop` prompt in §1 and follows AGENTS.md like any other contributor; this file only adds the loop and the merge rules.
State between iterations lives in [HANDOFF.md](../../HANDOFF.md); the work queue is [ROADMAP.md](../ROADMAP.md) §"Remaining work".

## 1. Starting the loop
```text
/loop Continuously execute the roadmap in a loop: **Plan → Implement → Verify**. Once a milestone is completed and verified, immediately proceed to the next milestone. Continue autonomously until roadmap finished.
```
The agent first reads AGENTS.md, HANDOFF.md and this file (AGENTS.md §0).

## 2. One iteration
1. **Pick** the first unchecked item of ROADMAP §"Remaining work" that the agent can do on this machine (§5 lists what it can't).
   HANDOFF §6 may name a more specific next step; it wins if it belongs to the same item.
2. **Plan**: read the owning spec section and the ACs it must meet; check the item against DECISION_LOG and OPEN_QUESTIONS
   (AGENTS.md §0 steps 3–4). Verify every SDK API in the pinned source (ios/SDKVERSION.md).
3. **Implement** in small commits with tests (AGENTS.md §12), on a work branch (§3).
4. **Verify**, reporting real output (AGENTS.md §0 step 5):
   - `scripts/prepush.sh`;
   - the app build (`xcodebuild -project ios/Halo.xcodeproj -scheme Halo-Debug -destination 'platform=iOS Simulator,name=iPhone 17' build`),
     which `prepush.sh` doesn't run;
   - the adapter contract tests the change touches, against `infra/dev`: `scripts/contract-test.sh <test> …` (no argument: the
     whole suite; tests whose fixture variable is missing skip themselves, so say which ones skipped);
   - for UI changes, run the app in the simulator and check the screen.
5. **Review** the branch diff (`/code-review` or an equivalent self-review for correctness, security, performance). Fix every
   high or medium finding before merging; list the rest in HANDOFF §5.
6. **Hand off and merge** (§3), tick the item in ROADMAP, then start the next iteration at once. Do not ask whether to continue. Between iterations wait only about 2 minutes (founder, 2026-11-20): schedule the next wakeup 120 s out.

## 3. Branches, pull requests and merging (D70)
- **When a pull request, and when just a commit (D75, founder).** A pull request only for a milestone or a big feature (a new
  screen or flow, a new port/adapter, a cross-layer change, anything that needs CI before it lands). A small change (a fix, a
  tweak, a polish item, a settings row, docs, a roadmap sub-item) is committed straight to `main` and pushed: no branch, no PR.
  Small changes are never batched into a branch just to open a PR for them. Before any push to `main`: `scripts/prepush.sh`
  passes, and HANDOFF.md is in the last commit (AGENTS.md §18). Never push a failing build to `main`.
- Big features: one branch per feature (or a coherent slice of one): `feat/<milestone>-<topic>` from an up-to-date `main`.
- Before the push: HANDOFF.md, ROADMAP status, specs, OPEN_QUESTIONS and DECISION_LOG updated (AGENTS.md §18).
- Open a pull request to `main` (`gh pr create`), body: what, why, checks run and their results, what wasn't verified.
- **The agent merges its own pull request** when all of these hold:
  1. every CI check on the pull request has completed and passed (`gh pr checks <n>` — never merge while one is pending or failing);
  2. `prepush.sh`, the app build and the touched contract tests passed locally on the pushed commit;
  3. the review of step 5 left no high or medium finding open;
  4. no change to a gate decision (G-FFI, G-NSE, G-UNREAD), a licence, a dependency (AGENTS.md §11), a security setting, or an
     accepted ADR — those wait for the founder (§5).
- Merge with `gh pr merge <n> --merge --delete-branch` (merge commit, like the earlier pull requests), then
  `git switch main && git pull --ff-only` and branch again for the next item.
- A failing CI check is fixed on the same branch; after three failed attempts on the same cause, record it in HANDOFF §5 and
  move to another item.
- Never force-push `main`, never rewrite merged history, never skip hooks (`--no-verify`).

## 4. Definition of done
- **Item:** behaviour implemented as specified, tests at the lowest sensible layer, docs updated, checks of §2 step 4 green,
  merged.
- **Milestone:** its exit criteria in ROADMAP §Milestones and the ACs of its specs are met *by tests*, or, where a check needs
  hardware or the founder (§5), the item is listed under "Needs the founder" in HANDOFF §5 with the exact check to run. The
  milestone is then marked "done except: …" in ROADMAP and the loop goes on to the next one.
- **Roadmap:** M0–M5 is the MVP ("the app meets the spec"); M6–M10 follow. The loop ends when every item is done or listed as
  needing the founder, and says so in HANDOFF §1.

## 5. What the agent doesn't do alone
Recorded in HANDOFF §5 under "Needs the founder", then the loop moves on:
- anything needing a **physical iPhone** (G-NSE AC-NSE-1…6, V-RS-1 on device, file-protection class, background push delivery);
- **Apple Developer** work: signing, provisioning, App Store Connect, APNs keys, TestFlight;
- **product decisions** not settled by the specs, DECISION_LOG or OPEN_QUESTIONS, and any change to an accepted ADR or gate outcome;
- adding or upgrading a **dependency** or the SDK pin (AGENTS.md §11);
- anything that costs money, publishes outside this repository, or needs credentials the agent doesn't have.

## 6. Local resources the loop relies on
- `infra/dev` Synapse at `http://localhost:8008` (`docker compose -f infra/dev/docker-compose.yml up -d`; the Docker CLI needs a
  throwaway `DOCKER_CONFIG`, HANDOFF §5).
- **Contract-test settings:** `~/.config/halo-dev/contract.env` (mode 600, outside the repository; `HALO_CONTRACT_ENV` overrides
  the path), in the format of [infra/dev/contract.env.example](../../infra/dev/contract.env.example). `scripts/contract-test.sh`
  loads it and never prints values. Accounts in it are throwaway local ones; their passwords never go into the repository, a
  commit, a log or a pull request. If the file is missing, run `infra/dev/create-fixtures.py` (accounts, rooms and the file);
  `contract-test.sh` runs it with `--new-e2ee` before the Encryption contract.
- **Offline-send contract:** `scripts/contract-offline-test.sh` runs `offlineSend` and stops/starts the dev Synapse
  (`docker stop`/`start`) when the test asks through files in `HALO_DEV_OFFLINE_DIR`; it always starts Synapse again and checks it is
  reachable when it exits. A normal `scripts/contract-test.sh` run skips that test. Run it after changing sending or the sync loop.
- An iOS 26 simulator (`iPhone 17` by default; `HALO_SIM` overrides it in `prepush.sh`).
- `gh` signed in to the repository.
