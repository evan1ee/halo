# Licence Compliance Strategy

> **Not legal advice.** This is an engineering compliance plan. Items marked ⚖️ require review by a qualified lawyer before any public distribution (D38).

## 1. Position
Halo is proprietary (LICENSE: all rights reserved). The goal is a **defensible** position: every component we distribute allows
proprietary binary distribution, every attribution duty is met, and there's a written record that Halo's code was written independently
of copyleft sources (ADR-0013). That's risk reduction, not a guarantee.

## 2. Usage modes and what they trigger

| Mode | In Halo | Obligations triggered |
|---|---|---|
| Depend on a library, unmodified | GRDB (SwiftPM), MatrixRustSDK prebuilt package | Licence + notices in the distribution |
| Link statically / dynamically into the app binary | All Rust crates inside `MatrixSDKFFI.xcframework` (dynamic framework); GRDB (static) | Same as distributing those works in binary form → notices for **all transitive crates** |
| Fork and modify | Not planned (D44) | Apache-2.0: state changes (§4b); MPL-2.0: publish the modified MPL files |
| Copy source | Not allowed for copyleft code; permissive snippets only with a header and a notices entry (CONTRIBUTING) | Licence of the copied code applies to that code |
| Distribute binaries | TestFlight (yes, it's distribution), App Store | Notices reach users (Acknowledgements screen) |
| Run server software | Synapse, MAS (AGPL), Sygnal (Apache) on the founder's server | Not distribution; AGPL §13 only for *modified* versions offered over a network. Never affects the client's licence |

## 3. Licence obligations

| Licence | Proprietary distribution | Obligations | Present in Halo |
|---|---|---|---|
| MIT, BSD-2/3, ISC, Zlib, 0BSD, Unlicense, CC0, MIT-0, BlueOak, BSL-1.0 (Boost) | ✅ | Keep the copyright + licence text with the distribution (some don't even require it in binaries; include anyway) | Yes (majority) |
| Apache-2.0 | ✅ | Licence text; pass on NOTICE file contents; mark modified files; patent licence from contributors, terminated if you sue over patents in the work | Yes (matrix-rust-sdk, vodozemac, components package, many crates) |
| MPL-2.0 | ✅ | File-level copyleft: modified MPL files must be available as source; notice + pointer to the source for unmodified use | Yes: `uniffi*`, `eyeball-im`, `imbl`, `imbl-sized-chunks` (unmodified) |
| Unicode-3.0 | ✅ | Notice | Yes (ICU crates) |
| OpenSSL / ISC parts of aws-lc | ✅ | Notices (⚖️ check the aws-lc notice set) | Yes (`aws-lc-sys`) |
| LGPL-2.1/3.0 | ⚠️ Avoid | Static linking requires enabling relinking; impractical on iOS | **None** (blocked) |
| GPL-2/3 | ❌ | The whole derivative under GPL; App Store terms conflict | **None** (blocked) |
| AGPL-3.0 | ❌ | GPL + network clause | **None** in the client (blocked). Element X is AGPL → behaviour-only reference |
| SSPL, BUSL, "Commons Clause", non-commercial | ❌ without review | — | None |

Don't assume an SDK's licence covers its dependencies: the inventory checks **every** transitive crate (F-LIC-2).

## 4. Process
1. **Gate:** every dependency change runs the licence check (`cargo deny` when building the SDK from source or for `core/`; for the prebuilt package, the inventory script diff against the matching SDK rev; for Swift packages, the reviewed list in [DEPENDENCY_INVENTORY.md](DEPENDENCY_INVENTORY.md)).
2. **Allowlist** (Rust): MIT, Apache-2.0, Apache-2.0 WITH LLVM-exception, BSD-2-Clause, BSD-3-Clause, ISC, Zlib, Unicode-3.0, MPL-2.0, CC0-1.0, 0BSD, Unlicense, BSL-1.0, BlueOak-1.0.0, MIT-0, OpenSSL. Anything else → manual review recorded in the inventory.
3. **Notices:** a script generates `THIRD_PARTY_NOTICES` (full licence texts + copyright lines + Apache NOTICE contents) from the inventory; the app shows it under Settings → About → Acknowledgements (D39).
4. **Per release:** regenerate the inventory for the exact shipped SDK version; diff; record in the release notes.

## 5. Compliance checklist
- [x] Proprietary LICENSE in the repository.
- [x] Clean-room policy (CONTRIBUTING.md, ADR-0013).
- [x] Rust inventory for the SDK at the pinned rev (with the sentry feature) — no GPL/LGPL/AGPL.
- [ ] Map the prebuilt package version → SDK commit (V-SDK-1) and confirm the prebuilt feature set (sentry included?) before the first TestFlight.
- [ ] Notices generator + Acknowledgements screen (M5).
- [ ] Apache NOTICE files collected (crates that ship `NOTICE`).
- [ ] MPL source pointers listed.
- [ ] ⚖️ Export compliance (non-exempt encryption; `ITSAppUsesNonExemptEncryption`, possible BIS self-classification) — before external TestFlight.
- [ ] ⚖️ Trademarks: product name and icon must not suggest affiliation with Element or the Matrix.org Foundation; "for Matrix" only descriptively.
- [ ] ⚖️ Legal review of this whole strategy before public release, including the founder's earlier exposure to Element X source (ADR-0013 §Context).

## 6. Risks
See [../RISK_REGISTER.md](../RISK_REGISTER.md) L1–L6.
