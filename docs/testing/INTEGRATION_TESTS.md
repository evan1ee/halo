# Integration Tests

## 1. Environments
| Environment | Contents | Use |
|---|---|---|
| `infra/test` (Docker Compose) | Synapse (pinned version, native sliding sync, registration with a shared secret, rate limits off), Postgres, MAS (optional profile), a TCP proxy for fault injection | CI scenario tests, local FFI runs |
| `infra/dev` | Synapse + Postgres with native password login (D64, [../../infra/dev/README.md](../../infra/dev/README.md)); Sygnal + pushkin from M1; MAS from M5 | Manual development |

Users are created per test run with random suffixes; every test starts from a fresh database (or a fresh namespace of users and rooms).

## 2. Suites

| Suite | IDs | Runs on |
|---|---|---|
| Read state | S01–S22 ([UNREAD_REGRESSION_TESTS.md](UNREAD_REGRESSION_TESTS.md)) | Linux CI (driver) + local Mac (FFI) |
| Auth | S-AUTH-1 password login · S-AUTH-2 restore offline · S-AUTH-3 soft logout · S-AUTH-4 logout wipes data | Local Mac |
| E2EE | S-E2EE-1 recovery-key restore decrypts history | Local Mac |
| Room list | S-RL-1 list matches the server's joined rooms; order by recency | Local Mac |
| Timeline | S-TL-1 back pagination; S-TL-2 jump to the read marker; S-TL-3 redaction in view | Local Mac |
| Messaging | S-MSG-1 send/receive text; S-MSG-2 reply; S-MSG-3 edit; S-MSG-4 reaction toggle; S-MSG-5 offline queue survives relaunch | Local Mac |
| Media | S-MED-1 image round trip; S-MED-2 EXIF stripped | Local Mac |
| Push | S-PUSH-1 pipeline with a fake fetch; S-PUSH-2 de-dup; S-PUSH-3 suppress already-read; S-PUSH-4 clearing | Local Mac (pipeline called directly) |
| Rooms/profiles/settings | S-ROOM-1..3, S-PROF-1..2, S-SET-1 | Local Mac |
| Stickers | S-ST-1 pack create + read back; S-ST-2 `m.sticker` seen by another client; S-ST-3 prefs sync | Driver + local Mac |
| Bots | S-BOT-1 scripted fake bot (replays the real bot's formats and reaction behaviour F-BOT-2/4) | Driver + local Mac |
| Activity | S-ACT-1 index from a list + confirmations | Driver |

## 3. Adapter contract tests
For every port: a shared test suite (`PortContractTests<P>`) run against the fake and the real adapter. A change to a port starts with a failing contract test.

## 4. Interop checks (manual, per milestone)
Element Web and FluffyChat against the dev Synapse: stickers, mentions, receipts, marked-unread, image packs.
