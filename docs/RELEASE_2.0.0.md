# Vesta 2.0.0 — release checklist and notes draft

This is the working checklist for tagging `v2.0.0`. It maps the release gates in
[V2_AUTHZ_PLAN.md §10.2](V2_AUTHZ_PLAN.md) to concrete steps. Tick items in the PR
that changes them. Tag only when every box is ticked.

## Scope

| Area | PR | Status |
|---|---|---|
| Receipts: on-device OCR, pairing, auto-pair, device limit | #12–#16 | merged |
| Capabilities model, signed-in through denials (V1) | #22 | merged |
| Native Budget sheet (stays **off** in 2.0.0) | #21 | merged, hidden |
| Calendar agenda, hestia `0.48.0` | #17 | merged |
| Features probe + `/api/me/capabilities` (V2a) | #23 | merged |
| One authoritative session record (V2b) | #24 | merged |
| App version 2.0.0 | #26 | merged |
| Code-paired device kept after a 401 and same-user sign-in | #28 | merged |
| QR sign-in (V3) | #25 | merged |
| Device-token exchange and rotation journal (V4) | #27 | merged |

## Gates

### Before UAT
- [x] Hestia authz PR 3 (#291) is merged and deployed as `0bf8940`, contract `0.54.0`. QR and device exchange went live on prod at 2026-11-25 17:22Z (`HESTIA_PUBLIC_ORIGIN` set, `activate-sessions-v2` run). Legacy sessions keep working.
- [x] The V3/V4 pins match the merged hestia spec, re-checked against that SHA: `qrRedeem` / `redeemQrLoginCode`, `exchangeNativeSession`, `QrRedeemRequest`, `QrRedeemSuccess`, `AuthDeviceTokenRequest`, `AuthDeviceTokenResult`, `AuthError`, and the `features` strings.
- [x] #25 is merged (342ff9e), then #27 is retargeted to `master` and merged (7f3a261).
- [ ] `make test` and `make coverage` are green on `master`. That includes both legacy decoder suites and the 45-locale catalog completeness test.
- [x] `PRIVACY.md` describes what 2.0.0 stores and sends (session record, exchanged device token, camera use for QR).
- [x] Xcode Cloud built `7f3a261` at 2026-11-25 14:46Z ("Archive - iOS": success). The build number is in App Store Connect.

### Gate 1 — older hestia (0.46.0 behaviour)
Covered by the unit tests: the features probe gets a non-200 → falls back to `whoami.role`; password sign-in, IOC, and viewer read-only all work; zero native Budget requests. There's no live 0.46.0 server any more, so this gate is satisfied by `FeaturesProbeTests`, `Legacy110ContractTests` and `LegacyReceipts090ContractTests`.

### Gate 2 — owner UAT on the phone (production hestia with PR 3)
Existing sessions keep working after `activate-sessions-v2`, so the upgrade doesn't sign you out. **Don't sign out before step 4.** In Vesta, signing out also unpairs the receipt device, and the exchange could then no longer keep the same device entry.
1. [ ] Install the 2.0.0 build over the current one. You are **still signed in**.
2. [ ] Toggle one light, open **Calendar** (the agenda covers the next 30 days), and send **one receipt**. Check that it shows up in hestia.
3. [ ] In Settings, if the receipts section asks you to sign in again to update the pairing, tap Sign in and use your password. This gives Vesta a native session, and the device exchange then runs with the old token as proof.
4. [ ] In hestia's device list (Budżet → Konta → Urządzenia), the iPhone is still **one entry, the same as before**. There is no "Nowe urządzenie" alert.
5. [ ] Send another receipt. It works.
6. [ ] Sign out in Vesta (this unpairs receipts, as expected). In hestia's browser UI, open the sign-in QR code and **scan it** with Vesta. Vesta shows the server address, you confirm it, and you are signed in.
7. [ ] Pair the iPhone if Vesta asks. This time a single "Nowe urządzenie" alert is expected. Send a receipt.

### Gate 2b — spouse (delegate) UAT
- [ ] The spouse's installed build keeps working against PR 3: sign-in, IOC and Calendar.
- [ ] After upgrading to 2.0.0, a receipt submitted by the spouse is attributed to the spouse and needs no match picker.

### Gate 3 — rollback safety
Covered by the unit tests: a PR 3 token moves to `rollbackQuarantine` on `401 device_token_invalid`, legacy pairing works again, and zero native Budget reads happen. A live rollback run is needed only if hestia actually rolls back.

### Gate 4 — before hestia PR 4
- [ ] Every household phone runs 2.0.0 before hestia retires the legacy routes (PR 4).

### Tag and release
- [ ] `git tag -a v2.0.0 -m "Release 2.0.0"` on the UAT'd commit, then push the tag.
- [ ] `gh release create v2.0.0 --title "v2.0.0 — receipts, calendar and the new sign-in" --notes-file <notes> --latest`

## Release notes draft

### Highlights
- **Receipts.** Photograph a paper receipt. The phone reads it on-device, removes card numbers, and sends only the text to hestia. Pair with a code or automatically after an admin sign-in.
- **Calendar.** A read-only agenda of the next 30 days from hestia's calendars, including recurring events. It shows a note when some events couldn't be expanded.
- **Sign in with a QR code.** Scan the code hestia shows in the browser. Vesta checks the server address and asks you to confirm before it sends anything.
- **Permissions, not roles.** Vesta now follows hestia's per-user permissions. Each part of the app appears only when you're allowed to use it, and losing access closes just that part, not your session.

### Under the hood
- One authoritative session record in the Keychain (this device only). Every request, live updates included, is bound to the server it was signed in to. Upgrading keeps you signed in.
- Receipt device tokens are exchanged for scoped tokens. A crash-safe rotation journal makes sure an interrupted exchange never loses a working pairing.
- Every hestia contract piece is hand-pinned from a reviewed hestia commit. Two legacy decoder suites keep older servers working.
- Each feature was implemented by Codex and reviewed by a second model family (Gemini, Kimi) before merge.

**Full changelog**: https://github.com/mateusz-klatt/vesta/compare/v1.1.0...v2.0.0
