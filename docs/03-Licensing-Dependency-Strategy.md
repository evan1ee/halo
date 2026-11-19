# Halo — Licensing and Dependency Strategy

Status: v0.1, engineering analysis. **This is not legal advice.** Items marked ⚖️ need professional
review before public distribution (D38).

## 1. Goal and stance

Halo is proprietary: all rights reserved, private repository (D2). The aim is a *defensible* position:
every distributed component has a licence that allows closed-source binary distribution, all
attribution obligations are met, and there is a record showing that Halo's own code was written
independently of AGPL code. Nobody can guarantee this outright; we reduce the risk and document it.

## 2. Usage modes and why they matter

| Mode | What it means here | Typical obligations |
|---|---|---|
| **Use as a dependency, unmodified** | matrix-sdk-ffi pinned by git rev; crates from crates.io; SwiftPM packages | Keep the licence and notices; attribution in the app |
| **Statically link** | All Rust crates end up in one static library inside the app binary | Same as distributing those crates in binary form. GPL/LGPL become a problem here (§4) |
| **Fork and modify a library** | Not planned (D3). If ever needed for an Apache-2.0 crate: mark changed files (§4b), keep NOTICE | Apache: notices + change notices. MPL: publish the *modified MPL files* |
| **Copy source code** | Pasting functions or files into Halo | Copied code keeps its licence. Forbidden for AGPL/GPL sources; allowed for permissive code only with attribution recorded in the file |
| **Distribute binaries** | TestFlight and the App Store count as distribution | Notices must reach users (acknowledgements screen). Running Synapse or Sygnal on your server is *not* distributing them |
| **Network use of AGPL software** | Running AGPL Synapse/MAS as a service | AGPL §13 applies to *modified* versions offered to users over a network. Unmodified Synapse: no source obligation in practice. It never affects the client's licence |

## 3. Licence obligations (summary)

| Licence | Proprietary binary distribution? | Obligations |
|---|---|---|
| **MIT / BSD-2/3 / ISC / Zlib / 0BSD / Unlicense / CC0 / BSL-1.0 (Boost)** | Yes | Keep the copyright and licence text in the distribution (Zlib/Boost: for binaries, often not even required; we include it anyway) |
| **Apache-2.0** | Yes | Include the licence text; pass on the NOTICE file contents if the project has one; mark changes to modified files; **patent grant** to you, which ends if you bring patent litigation over the work |
| **MPL-2.0** | Yes | Copyleft per file: if you *modify* an MPL file, that file's source must be available. Unmodified use: notice plus pointing to where the source is. Can be combined with proprietary code |
| **Unicode-3.0** | Yes | Include the notice |
| **LGPL-2.1/3** | Risky on iOS | Static linking requires letting users relink with a modified library; the App Store makes that impractical. **Avoid** |
| **GPL-2/3** | No (for our goal) | Distributing a derivative requires releasing the whole program under the GPL. The App Store's terms are also widely considered incompatible with GPL. **Block** |
| **AGPL-3.0** | No | GPL plus a network clause. **Block** for all client code, copied or linked |
| **SSPL / BUSL / Commons Clause / "non-commercial"** | Depends; not OSI | **Block** without review |

Note: `BSL-1.0` in the inventory is the **Boost** Software License (permissive), not the Business Source License.

## 4. Dependency inventory

### 4.1 Rust (verified)

Generated with `cargo metadata --filter-platform aarch64-apple-ios` for `bindings/matrix-sdk-ffi`
at matrix-rust-sdk rev `7ff8855` (2026-11-18), normal and build dependencies, default features.
Full list: `docs/licensing/rust-deps-matrix-sdk-ffi.csv` (552 crates).

| Licence family | Crates | Notes |
|---|---|---|
| MIT and/or Apache-2.0 (any form) | ~460 | Permissive |
| Unicode-3.0 (alone or combined) | 37 | ICU data crates |
| **MPL-2.0** | 19 | `uniffi*` (17 incl. `eyeball-im`), `imbl`, `imbl-sized-chunks`. Use unmodified; record source links |
| BSD-2/3-Clause | ~12 | dalek crypto crates, zstd |
| ISC | ~6 | rustls-webpki, ring, aws-lc-rs (with others) |
| Zlib / Unlicense / CC0 / 0BSD / BlueOak / Boost | ~15 | Permissive |
| **GPL / LGPL / AGPL** | **0** | ✅ none found |

Key components:

| Component | Licence | Role |
|---|---|---|
| matrix-rust-sdk (`matrix-sdk`, `-base`, `-crypto`, `-ui`, `-sqlite`, `-search`, `-ffi`) | Apache-2.0 | Matrix foundation |
| vodozemac | Apache-2.0 | Olm/Megolm cryptography |
| ruma | MIT | Matrix types |
| UniFFI | MPL-2.0 | Rust↔Swift bindings (build-time generator plus runtime scaffolding) |
| tantivy (via `matrix-sdk-search`, default feature `experimental-search`) | MIT | Search |
| aws-lc-rs / aws-lc-sys (rustls backend) | ISC + Apache-2.0 + OpenSSL-derived permissive (see crate) | TLS crypto. ⚖️ confirm notice text; consider the `ring` backend if aws-lc's notices are heavy |
| SQLite (bundled via `libsqlite3-sys`) | Public domain | Store |
| SQLCipher (planned for `halo-store`) | BSD-3-Clause (Community Edition) | Encryption of `halo.sqlite`; attribution required |

**Feature hygiene:** turn off upstream default features we don't need (e.g. `sentry`, which is already off;
review `experimental-*`), both to shrink the binary and to shrink the licence surface. Re-run the inventory
on every SDK bump (it's automated in CI).

### 4.2 Swift (planned; keep minimal)

| Package | Licence | Status |
|---|---|---|
| Apple frameworks (SwiftUI, UserNotifications, PhotosUI, AVKit, Charts) | Apple SDK terms | OK |
| swift-markdown / AttributedString Markdown (Apple, Foundation) | Apache-2.0 / Apple | Prefer Foundation built-ins |
| An animated image renderer (WebP/APNG/GIF) | Use ImageIO (supports animated WebP/GIF/APNG on iOS 14+) | No dependency needed |
| swift-snapshot-testing (tests only, not distributed) | MIT | OK, test-only |
| lottie-ios | Apache-2.0 | Not used (D13) |

Rule: every new SwiftPM dependency gets a row here and a PR review; test-only packages are flagged as such.

### 4.3 Server side (not distributed with the app)

| Component | Licence | Note |
|---|---|---|
| Synapse | AGPL-3.0 (Element; previously Apache-2.0) | Run unmodified. If modified *and* offered to other users over the network, the source of the modifications must be offered (§13) |
| MAS (matrix-authentication-service) | AGPL-3.0 | Same |
| Sygnal | Apache-2.0 | OK |
| matrix-bot (your own) | MIT (your copyright) | Its template strings are used as test fixtures; attribution included |

### 4.4 Element X iOS

AGPL-3.0, with a separate commercial licence (verified: `LICENSE`, `LICENSE-COMMERCIAL`). **No
code, assets, strings, icons or layouts are copied.** Element X is a behavioural reference only (§6).

## 5. Compliance checklist

- [x] Replace the repository's MIT `LICENSE` with a proprietary notice (done in this change).
- [ ] `cargo-deny` in CI: `licenses.allow = [MIT, Apache-2.0, Apache-2.0 WITH LLVM-exception, BSD-2-Clause, BSD-3-Clause, ISC, Zlib, Unicode-3.0, MPL-2.0, CC0-1.0, 0BSD, Unlicense, BSL-1.0, BlueOak-1.0.0, MIT-0, OpenSSL]`; explicit `deny` for GPL/LGPL/AGPL/SSPL/BUSL; `bans` for duplicate-version alerts; `sources` restricted to crates.io + the matrix-org git repo.
- [ ] Generate `THIRD_PARTY_NOTICES` from cargo metadata (e.g. `cargo-about`, MIT/Apache) plus a hand-maintained Swift section; ship it as an in-app Acknowledgements screen (D39).
- [ ] Include the Apache-2.0 NOTICE contents where crates ship a NOTICE file.
- [ ] MPL-2.0: list the crates with links to their source; never vendor-modify them.
- [ ] Record the pinned SDK rev and inventory snapshot per release (release checklist).
- [ ] Clean-room policy in CONTRIBUTING.md (D37); reference notes in `docs/reference-notes/` are prose only.
- [ ] AI-assistant hygiene: never paste AGPL code into prompts; review generated code for verbatim copying; prefer small, spec-driven prompts.
- [ ] ⚖️ Export compliance: the app uses non-exempt encryption (E2EE). Apple's `ITSAppUsesNonExemptEncryption` and possibly a US BIS self-classification/annual report. Review before the App Store.
- [ ] ⚖️ Privacy: App Store privacy labels, a privacy policy (the push gateway sees push metadata: room and event ids).
- [ ] ⚖️ Trademarks: avoid "Element" and "Matrix" in the product name or marks beyond descriptive use ("for Matrix"); check the Matrix.org Foundation trademark guidelines.
- [ ] ⚖️ Patent: Apache-2.0 patent grants cover contributors' patents in those works only; no wider patent clearance.

## 6. Clean-room procedure (D37)

1. Sources allowed while designing: Matrix spec, MSCs, matrix-rust-sdk (Apache-2.0) code and docs,
   the running Element X app (observed behaviour), public blog posts and talks.
2. Not allowed: reading Element X Swift source while working on Halo; copying its assets,
   strings, layouts or file structure; importing code from the developer's earlier Element X fork.
3. Reference notes describe *behaviour and protocol* in prose ("on receipt X, the badge Y"), never code.
4. Commits are by the author; AI-generated code is reviewed like any contribution.
5. ⚖️ The developer has seen Element X source in the past (from the fork). Record this honestly here;
   it's the reason for the behaviour-only rule from now on. Have a lawyer confirm it's sufficient before release.

## 7. Risk assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| A copyleft crate enters through an SDK bump | Medium | High | cargo-deny gate on every PR |
| Claim of derivation from Element X | Low | High | Clean-room record, independent design docs, a different architecture |
| MPL file modified by accident | Low | Low | No vendoring; git dependencies only |
| A missing notice in the shipped app | Medium | Medium | Generated acknowledgements; release checklist |
| Upstream relicenses matrix-rust-sdk (e.g. to AGPL, as happened to Synapse) | Low–Medium | Very high | Pinned revs stay Apache-2.0 for good; watch upstream; budget for a hard fork of the last Apache rev as a fallback ⚖️ |
| Export compliance error | Medium | Medium | Legal review before public release |
