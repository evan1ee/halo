# Next session — handoff prompt

Copy the block below into a new coding session to continue development. Keep it current: whoever finishes a piece of
work updates "Where things stand" and the task list in the same pull request.

Last updated: 2026-11-19 (after M0a, pull request evan1ee/halo#1).

```text
Continue development of Halo (repository evan1ee/halo).

## Read first
1. AGENTS.md completely — it is the binding engineering contract (CLAUDE.md points to it).
2. docs/ROADMAP.md, section "M0 without a Mac": M0a (Linux part) is done; M0b is what remains.
3. docs/architecture/MODULE_BOUNDARIES.md, docs/matrix/PORTS_CONTRACT.md, docs/matrix/SDK_INTEGRATION.md,
   docs/features/AUTHENTICATION.md, docs/features/ROOM_LIST.md, docs/development/DEVELOPMENT_SETUP.md (§3 has the
   one.mbm.halo identifier table), docs/OPEN_QUESTIONS.md.

## Where things stand
- Phase 0 documentation is approved. Decisions D1–D66 and ADR-0001…0016 are accepted; don't change them silently —
  propose a new ADR instead.
- Key decisions from the last session: namespace root `one.mbm.halo` for every identifier (D63); M0 uses Synapse's
  native username/password login, MAS only from M5 (D64); push notifications are synchronisation hints, never truth —
  the local unread engine is the sole authority for counts and the badge, and no push may set `aps.badge` (D65,
  ADR-0015, AGENTS.md §4 principle 9); the NSE has its own gate G-NSE at the end of M1 with AC-NSE-1…6 (D66, ADR-0016).
- Work so far is on branch `claude/blissful-galileo-3400g9`, in pull request evan1ee/halo#1 (Phase 0 + M0a).
  First check whether #1 is merged, and what its CI checks reported; fix any failures before building on it.
- M0a delivered: infra/dev (Synapse v1.165.0 + Postgres, `infra/dev/smoke.sh`), packages HaloFoundation, HaloDomain
  (SessionPort, RoomListPort, KeychainPort), HaloTestSupport (fakes + SessionPortContract/RoomListPortContract),
  HaloApplication (SessionCoordinator, RoomListCoordinator); scripts check-boundaries.sh, rust-license-inventory.py,
  prepush.sh; CI workflows swift-linux, boundaries, secrets, licenses. Pinned SDK: prebuilt package 26.11.17 ← SDK
  commit b93751e (ios/SDKVERSION.md).

## Task: finish M0 (M0b) — needs a Mac with Xcode for the iOS 26 SDK
1. V-CI-2: compare `xcrun swift --version` with the Linux CI image (swift:6.2-noble, Swift 6.2.4); align and record.
2. Xcode project `ios/Halo.xcodeproj` with only the composition roots (app `one.mbm.halo`, NSE `one.mbm.halo.nse`),
   identifiers exactly as in DEVELOPMENT_SETUP §3, `HALO_NAMESPACE` defined once in ios/Config/Base.xcconfig,
   iOS 26.0, Swift 6 strict concurrency, warnings as errors.
3. HaloMatrixAdapter (the only importer of MatrixRustSDK, pinned by exact version + checksum from ios/SDKVERSION.md):
   implement SessionPort and RoomListPort; map upstream types to domain values immediately; every TaskHandle owned by
   a SubscriptionToken; all upstream errors through one ErrorMapper → HaloError, with a unit test per error kind.
   Verify each API you use in the SDK source at commit b93751e; don't invent names.
4. Run SessionPortContract and RoomListPortContract against the real adapter on infra/dev (local Mac, simulator).
5. HaloPlatform: KeychainPort (afterFirstUnlockThisDeviceOnly, non-synchronisable, access group
   <TeamID>.one.mbm.halo.shared) and the HaloLog os.Logger sink with privacy annotations.
6. Extend scripts/check-boundaries.sh with the adapter rule: no upstream type in a public/package signature.
7. V-SQL-1 smoke test (SDK client + a GRDB database in one process); V-APPLE-1 (check each Apple fact against current
   Apple documentation, record links in docs/SOURCES.md).
8. Exit criterion: password login against infra/dev shows the room count via the ports; CI green.
Update the documentation in the same commits (ROADMAP status, OPEN_QUESTIONS, SOURCES, PORTS_CONTRACT).

## If no Mac is available yet, do this instead (Linux-only)
- V-APPLE-1 from Apple's documentation (record sources; no assumptions left unlabelled).
- M1 preparation: Halo's Sygnal pushkin in infra/sygnal/ (ADR-0015): count-only notifications → background pushes,
  never `aps.badge`, server counts stripped; unit tests over Synapse notification fixtures; pushkin.yml workflow.
  Pin the Sygnal version; the device part of V-PUSH-5 still needs an iPhone, so say so.
- Don't start the Xcode project or the adapter without a Mac; don't write code you can't compile and test.

## Working rules (from AGENTS.md — follow them exactly)
- Run the relevant checks (scripts/prepush.sh, scripts/validate-docs.sh, scripts/check-boundaries.sh, swift test with
  -warnings-as-errors) and report the commands and their real output. Never claim something passed without running it;
  say explicitly what you couldn't run.
- Every behaviour change ships with tests; every bug fix adds a regression test; no sleeps in tests.
- Conventional Commits with a module scope, one logical change per commit, docs in the same commit; no secrets.
- Don't decide open questions silently: validate as documented, or stop and ask.
- Commit on a working branch and open a pull request when a milestone part is complete; end with a short summary of
  what was done, what was verified, and what remains. Update docs/development/NEXT_SESSION.md for the session after.
```
