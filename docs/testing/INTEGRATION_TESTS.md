# Integration Tests

## 1. Environments
| Environment | Contents | Use |
|---|---|---|
| `infra/test` (`run.sh`; Docker Compose, thrown away after each run) | Synapse (pinned version, relaxed rate limits), in-memory Postgres, the fault proxy ([TEST_STRATEGY.md](TEST_STRATEGY.md) §5) | CI scenarios, fault tests, interoperability tests |
| `infra/dev/scale-fixtures.py` (`halo-scale`, port 8108) | Its own Synapse with accounts of 300 and 1,000 rooms, a 10,000-member room and a 20,000-event media room (ROADMAP M17-3); `remove --yes` deletes all of it | Scale and performance measurements |
| `infra/dev` | Synapse + Postgres with native password login (D64, [../../infra/dev/README.md](../../infra/dev/README.md)); Sygnal + pushkin from M1; MAS from M5 | Manual development |

Users are created per test run with random suffixes; every test starts from a fresh database (or a fresh namespace of users and rooms).

## 2. Suites

| Suite | IDs | Runs on |
|---|---|---|
| Read state | S01–S29 ([UNREAD_REGRESSION_TESTS.md](UNREAD_REGRESSION_TESTS.md)) | Linux CI (driver) + local Mac (FFI) |
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
| Identity changes (`infra/test/run.sh identity`) | a second account resets its identity: alert, accept, alert again after the next reset · a device with no key and no verifier resets: verified, backup on, new key unlocks a third device, old key refused | Local Mac |
| Message search (`infra/test/run.sh search`; S-SRCH-6 as a store test) | S-SRCH-1 encrypted room, live · S-SRCH-2 encrypted history after recovery on a new device · S-SRCH-3 late key · S-SRCH-4 kill and resume in the history lane · S-SRCH-5 edit and deletion while not loaded · S-SRCH-6 sign-out leaves nothing · S-SRCH-7 no request carries the query | Local Mac |

## 3. Adapter contract tests
For every port: a shared test suite (`PortContractTests<P>`) run against the fake and the real adapter. A change to a port starts with a failing contract test.

## 4. Interoperability matrix (V-INTEROP-1)
Two halves. **Wire level, automated:** `infra/test/run.sh interop` (`InteropTests`): a plain HTTP client reads what Halo sends and sends what other clients send, with the contents the specification and MSC3381, MSC3488 and
MSC3245 give. Both directions pass (2026-11-25) except the two gaps below, which the tests hold as known issues. **In the other apps, by hand:** the checklist, per milestone (TEST_STRATEGY §8b); an agent can't install or sign in to them.

| Kind | Halo → others (wire) | others → Halo (wire) | Element Web: sent / received | Element X: sent / received |
|---|---|---|---|---|
| Text, formatted text | ✅ | ✅ | ☐ / ☐ | ☐ / ☐ |
| Mention | ✅ pill and `m.mentions`; plain text shows the Markdown link (**GA-30**) | ✅ | ☐ / ☐ | ☐ / ☐ |
| Reply, thread reply | ✅ reply | ✅ both; the old quote fallback is stripped | ☐ / ☐ | ☐ / ☐ |
| Edit, deletion | ✅ with fallback | ✅ | ☐ / ☐ | ☐ / ☐ |
| Reaction | ✅ | ✅ | ☐ / ☐ | ☐ / ☐ |
| Notice, emote | not sent by Halo | ✅ | — / ☐ | — / ☐ |
| Photo, caption, without `info` | ✅ photo | ✅ all | ☐ / ☐ | ☐ / ☐ |
| Video | ✅ `m.video`, no dimensions or thumbnail checked | ✅ with thumbnail and duration | ☐ / ☐ | ☐ / ☐ |
| Audio, voice message | ✅ as `m.audio` (a file in other clients; voice markup is M20-2) | ✅ both | ☐ / ☐ | ☐ / ☐ |
| File | ✅ | ✅ | ☐ / ☐ | ☐ / ☐ |
| Location | ✅ | ✅ | ☐ / ☐ | ☐ / ☐ |
| Poll | ✅ with fallback text | ✅ shown | ☐ / ☐ | ☐ / ☐ |
| Sticker | ✅ | ✅ | ☐ / ☐ | ☐ / ☐ |
| A type Halo doesn't know | — | ❌ missing from the timeline (**GA-31**) | — / ☐ | — / ☐ |
| Each of the above in an encrypted room | Halo ↔ Halo contract tests | Halo ↔ Halo contract tests | ☐ / ☐ | ☐ / ☐ |
| Receipts, marked unread, image packs | contract tests | contract tests | ☐ / ☐ | ☐ / ☐ |

**By hand (👤, about an hour).** `HALO_TEST_KEEP=1 infra/test/run.sh scenarios F01` leaves the server running (Element Web on this Mac can use `http://localhost:8208`; Element X needs `infra/dev` on the LAN). Sign in to Halo and the
other app with two accounts in one plain and one encrypted room; send each row both ways; tick "sent" when the other app shows Halo's message as that kind, "received" when Halo does. Sign: name, date, app versions. A row that fails becomes a GA row in the ROADMAP.

| Signed by | Date | Halo | Element Web | Element X |
|---|---|---|---|---|
| — | — | — | — | — |
