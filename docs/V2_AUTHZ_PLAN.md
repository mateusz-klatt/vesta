# Vesta v2 Authorization & Sign-In Adoption Plan (Revision 7)

> **Target release:** Vesta `2.0.0` (shipped Receipts + Calendar PR #17 + Hestia v2 AuthZ adoption; native Budget reads remain default-off outside the `2.0.0` gate)
> **Source of truth:** `AUTHZ_DESIGN_5e69ecd.md` — Part A (v4), Part B (v5 amendments, **take precedence over Part A**), and Part C + addendum §§1–11 (authoritative wire contract `@5e69ecd`).
> **Runtime baseline:** Swift 6 strict concurrency, SwiftUI, iOS 26 deployment target, zero new third-party dependencies.

### Contract Classification Legend
- **[Approved Wire — Part A / B / C]**: Frozen server behavior/schema from `AUTHZ_DESIGN_5e69ecd.md`.
- **[Vesta Client Design]**: Vesta-internal types, concurrency rules, UI gating, and state-machine invariants.

*(All wire questions — including `prior_token` proof rejection (`Part C §10`) and native Budget read scope (`Part C §11`) — are resolved by `@5e69ecd`; zero OPEN items remain.)*

### Changelog (Rev 6 → Rev 7)
- **Blocker 1 (`§§5.4–5.5` Single `applyIOCGrant` & discovery error taxonomy):** Replaced capability-source-specific cleanup with one helper `applyIOCGrant(_ granted: Bool)` invoked after **every** current capability publication (`.initialAuth`, `.foreground`, `.userPull`, `.denial`); losing `ioc.view` cancels `eventTask`, bumps `discoveryGeneration`, and clears IOC; replaced draft prose with explicit discovery-failure classification (`transient` network/`5xx` → back off & retry inside SSE loop with zero `makeEvents()`; `401`/`403`/cancellation → stop loop immediately); added `testLiveStreamFollowedByUserPullWithdrawingIOCGrantCancelsSSEAndClearsIOC` while preserving `testForegroundResyncsSnapshot`.
- **Blocker 2 (`§§6.1, 6.3, 7.2` One-way legacy migration & snapshot-before-clear):** Made `1.x` legacy `"backend"` → `"backend-session"` migration one-way via durable marker `"backend-legacy-migrated"` so any launch finding `"backend-session"` or `"backend-legacy-migrated"` deletes `"backend"` and never re-migrates; required `signOut()` and `saveAndConnect(_:)` to capture an immutable cleanup snapshot *before* deleting both `"backend-session"` and `"backend"`; added interruption tests for post-write crash followed by `signOut()` and changed-origin server switch.
- **Blocker 3 (`§§8.1–8.3` `.outcomeUnknown` denial persistence & session-match guard):** Reconciled Table A with `§8.2` so `401`/`403` during a retry from `.outcomeUnknown` preserves `RotationJournalRecord` and `priorToken` quarantine across denials and restarts (deleting/clearing only on initial `.intent`/`.sent` denial, verified `200`, or `409 prior_invalid`); required active session match on `(origin, capturedActor, slotTokenID)` before retry/promotion; added `testLostSuccessOutcomeUnknownFollowedBy401Or403PersistsJournalAndQuarantineAcrossRestart`.
- **Non-blocking notes (`§§2, 8.1, 8.3, 11`):** Attributed `400 budget_auth_ambiguous` accurately to `Part C §11` (noting `Part C §3` omits it on `/api/auth/device-token`, while Vesta keeps that call cookie-free and will verify exact server response against V4); updated `409 device_token_limit_reached` guidance to stop retries, preserve device-identifying metadata, and direct delegates to the ledger owner (plus full-5-slot test); added `V3` verification that the post-confirm features probe uses the isolated transport.

---

## 1. Summary & Dependency Map

Vesta `1.1.0` authenticates with an un-scoped Keychain bearer (`TokenStore`), reads `GET /api/whoami` (`{user, role}`), hard-codes role checks in `Control.isReadOnly(role:)` and `Control.canAddReceipts(role:)`, routes control errors into `.failed` (`RootView` sends `.failed` back to `ConnectView`), unconditionally requires `/api/discovery` and `/api/events` to reach `.ready`, and pairs receipts via password replay (`device-token/login`) or 8-char code (`device-token/redeem`).

Hestia's redesign separates `browser` vs `native` v2 sessions (`credential_generation`), introduces `GET /api/auth/features` (`Part C §6`) and `GET /api/me/capabilities` (`Part B §5`, `Part C §1`), adds HTTPS-only QR sign-in (`POST /api/auth/qr-redeem`, `Part C §§3, 5`), adds native-session device exchange (`POST /api/auth/device-token` with `owner_key`, `prior_token` validation/`409 device_token_prior_invalid`, and `budget.view` + `budget.receipts.*` scope, `Part C §§2, 3, 5, 7, 8, 10, 11`), and freezes `GET /api/calendars/instances` at hestia `0.48.0` (`Part C §9`). Vesta `2.0.0` delivers this across **V1, V2a, V2b, V3, V4, V5** (+ optional post-2.0.0 **V6**), keeping `0.46.0` compatibility for legacy servers/clients and keeping native Budget reads default-off behind §10.3's 4-part gate outside the `2.0.0` release gate.

### Hestia ↔ Vesta Dependency Map

| Vesta PR | Scope | Hestia Dependency | Effort | Buildable Today? |
|---|---|---|---|---|
| **V1** | `Capabilities` model (`deviceEligibleIDs` vs `deviceEligibleReceiptIDs`), `403` initial vs signed-in transitions, discovery-gated SSE startup, post-ready `403` / `ioc.view`-loss teardown, full fencing | **None** (`0.9.0` spec, `whoami` in prod; arbitrary mock capabilities in tests) | **M** | **Yes — merge now** |
| **V2a** | OpenAPI subset pin (`GET /api/auth/features`, `GET /api/me/capabilities`), pure probe vs coherent publication, signed-out `401` feature publication, `refreshRevision` rules, dual `v1.1.0` + `dd5df46` `0.9.0` decoder suites | **Hestia PR 2** (`GET /api/auth/features`, `GET /api/me/capabilities`, `Part B §5`, `Part C §§1, 6`) | **M** | Probe/refresh behind protocol now; pin after PR 2 |
| **V2b** | Single-owner `@MainActor` + `CredentialSessionStore` (`OSAllocatedUnfairLock`) publication, single authoritative Keychain `AuthoritativeSessionRecord` + `commitID`-linked `BackendURLStore` reconciliation, immutable REST `BoundSession` & SSE snapshots, `(origin, actor, owner_key)` store + `provenance` default | **None** (`Part C §§7–8` storage model; `prior_token` remote call activates in V4) | **L** | **Yes** |
| **V3** | QR sign-in (`hestia-login:<origin>#<code>`), shared `QRScannerView`, pre-probe QR attempt fence holding local probe until commit, shared authority fixtures + HTTP-auth challenge block, isolated transport, unified commit order | **Hestia PR 3** (`features ∋ "qr_login"`, `POST /api/auth/qr-redeem`, `Part C §§3, 5, 6`) | **L** | Parser, UI, isolated transport & commit tests now; pin after PR 3 |
| **V4** | Device exchange (`POST /api/auth/device-token`), split Decision Table (`Part C §§10–11`: proof-bearing vs fresh + `200` invariant validation + `409 device_token_prior_invalid`), persisted 4-state `RotationJournalRecord`, rollback quarantine, scoped `ReceiptSessionScope`, default-off native Budget skeleton (§10.3) | **Hestia PR 3** (`features ∋ "device_exchange"`, `POST /api/auth/device-token`, `Part C §§2–8, 10–11`) | **L** | Logic & mocks now; pin after PR 3 |
| **V5** | Calendar Agenda PR #17 merge (`APIClient: CalendarAPI`, server `instance_id`, open-agenda discard on revocation/switch, gated by `features ∋ calendar_instances && canViewCalendar`, `0.48.0` schema), `2.0.0` release bump & gates | **Hestia `0.48.0`** (`features ∋ "calendar_instances"`, `GET /api/calendars/instances`) **+ PR 3** | **M** | After `0.48.0` + PR 3 |
| **V6** *(post-2.0.0)* | Optional removal of `whoami` fallback & `device-token/{login,redeem}`; unhide native Budget reads (`budget_native_read`) | **Hestia PR 4** (after household upgrade & `0.46.0` window closes) | **S** | After `2.0.0` adoption |

---

## 2. Approved Wire Contract Baseline (`AUTHZ_DESIGN_5e69ecd.md` Parts A, B, C §§1–11)

1. **`GET /api/auth/features`** `[Approved Wire — Part C §6]` (hestia PR 2):
   - Public, unauthenticated, `Cache-Control: no-store`. Returns `{"auth_contract": 2, "features": [...], "qr_origin": "https://…" | null}` (`features` is a subset of `"capabilities"`, `"qr_login"`, `"device_exchange"`, `"calendar_instances"`, `"budget_native_read"`).
   - Servers older than PR 2 answer `401`, `403`, or `404` (`0.46.0` admin floor before routing). **Any response other than `200` carrying `auth_contract >= 2` means legacy:** use `whoami.role`, show no QR sign-in for that server, and skip `POST /api/auth/device-token`. **Never infer support from a `404` or `403` on `/api/me/capabilities`.**

2. **`GET /api/me/capabilities`** `[Approved Wire — Part B §5, Part C §1]` (hestia PR 2):
   - Authenticated, `Cache-Control: no-store`. Shape: `{"user": "…"|null, "installation_permissions": [...], "own_budget": {"permissions": [...], "can_view": bool, "can_use_receipts": bool, "can_manage_devices": bool}|null, "delegated_receipts": {"permissions": [...], "can_use": bool}|null, "household_available": bool}`.
   - Delegates never see the owner's username. Auth-off mode returns `user: null` and `installation_permissions` listing the full ordinary catalog.
   - In PR 2 (`Part B §§3–5`): `own_budget.can_use_receipts` requires a provisioned self-owner with all four receipt permissions; `can_manage_devices` is independent; `delegated_receipts` is `null`; `/api/whoami` stays `{user, role}` (`"viewer"`, `"operator"`, `"admin"`, or both `null`).

3. **`POST /api/auth/qr-redeem`** `[Approved Wire — Part A QR sign-in, Part C §§3, 5]` (hestia PR 3, `"qr_login"`):
   - HTTPS-only; request `{"origin": "…", "code": "…"}`; rejects `Cookie` and `Authorization`. `200` always returns `{"ok": true, "user": "…", "token": "…"}` without `Set-Cookie`.
   - Errors (`{"error": {"code": …}}`): `400 qr_auth_ambiguous`, `400 qr_origin_mismatch`, `401 qr_code_invalid`, `429 qr_rate_limited` (`Retry-After`), `503 auth_origin_unavailable`.

4. **`POST /api/auth/device-token`** `[Approved Wire — Part A Device exchange, Part C §§2, 3, 5, 7, 8, 10, 11]` (hestia PR 3, `"device_exchange"`):
   - Allowed over plain-HTTP LAN and HTTPS with a versioned native session (`v2.<payload>.<mac>`, `Authorization: Bearer …`). `Part C §11` explicitly pins `400 budget_auth_ambiguous` when both `Cookie` and `Authorization: Bearer` are sent on native budget reads, whereas `Part C §3` does not specify it for `/api/auth/device-token`; Vesta keeps `/api/auth/device-token` strictly cookie-free (`URLSession` without cookie storage) and will verify the exact mixed-carrier response once the V4 server contract is emitted.
   - Request: `{"device_name": "…", "prior_token": "…"?}`. No separate read-scope parameter.
   - Response (`200`): `{"token", "token_id", "scope", "actor", "owner", "owner_key", "issued_permissions": […], "expires_at"}`:
     - **`issued_permissions` (`Part C §11`):** `effective_grants ∩ {budget.view, budget.receipts.add, budget.receipts.view, budget.receipts.edit, budget.receipts.match}`. Non-empty intersection is eligible (so a `budget.view`-only owner receives a token).
     - **`scope` (`Part C §11`):** `"receipts"` when `issued_permissions` contains only `budget.receipts.*`, and `"device"` otherwise (e.g. includes `budget.view`).
     - **`owner_key` (`Part C §7`):** opaque per-installation HMAC of target owner (`hestia/auth/owner-key/v1`), never the username. Bind tokens to `(origin, actor, owner_key)`.
   - **`prior_token` outcomes (`Part C §§8, 10`):**
     - Valid proof: `200`, old token retired server-side, `token_id` preserved. For legacy 43-char self-owner token migration (`Part C §8`, no introspection route), server binds `actor = owner` (the self slot only; never migrates third-party delegate tokens).
     - Rejected proof (unknown, revoked, expired, or bound to a different actor/owner): **`409 device_token_prior_invalid`** (nothing issued, nothing revoked). **ONLY** this code permits Vesta to drop `prior_token` locally and repeat `POST /api/auth/device-token` without `prior_token` (new `token_id`, raises `"Nowe urządzenie"` alert), followed by optional best-effort self-revoke of the old `token_id` **retaining the full old bearer + old origin** (`DevicePairingAPI.swift:137` — `token_id` alone cannot authorize self-revoke).
     - `401` (missing/stale native session) or `403 budget_forbidden` (no eligible target): keep `prior_token` intact, retry later, **never** revoke on these codes.
     - `409 device_token_limit_reached`: 5 active slots per `(owner, actor)`.
   - Self-revoke stays on `POST /api/budget/receipts/device-token/revoke` with `{"token_id": "…"}` (`Part B §4`), requiring `Bearer <device_token>` against its issuing origin.

5. **`POST /api/budget/receipts/confirm`** `[Approved Wire — Part C §4]`: Keeps its `0.9.0` shape including `"link": null` (`ExplicitNullsMiddleware` unchanged).

6. **`GET /api/calendars/instances`** `[Approved Wire — Part C §9]` (`0.48.0`, `"calendar_instances"`):
   - Query: `from` (inclusive), `to` (exclusive), `group?`, `tz?` (IANA, default UTC).
   - Response (`200`): `{enabled, groups, truncated, instances[{instance_id, event_id, revision, group, summary, location, start, end, all_day, status, recurrence_id}]}`. Absent → omitted from `features`; disabled → `200 {enabled: false}`; missing `calendar.view` → `403`.

7. **Native Budget Read Routes** `[Approved Wire — Part C §11]` (hestia PR 3, `"budget_native_read"`):
   - Device token bearing `budget.view` (`Authorization: Bearer <device_token>`, zero `Cookie` → cookie+bearer `400 budget_auth_ambiguous`, live grants re-intersected at use) may GET with `0.46.0` bodies: `/api/budget/status`, `/api/budget/analytics/{monthly-budget, monthly-budget/charts, transactions, overview, categories}` (additive to receipt allowlist + self-revoke in `BearerAuthMiddleware`). All other budget routes return `403 budget_forbidden` to device tokens.

8. **PR 2 Rollback Behavior** `[Approved Design — Part B §4, Part C §6]`:
   - `features` advertises `"capabilities"` without `"qr_login"`, `"device_exchange"`, or `"budget_native_read"`; rejects PR 3 device tokens with `401 device_token_invalid`; restricts legacy receipt routes + pairing to full-profile self-owners (`403 budget_forbidden` for delegates). PR 2 `own_budget.can_view == true` authorizes browser Budget UI, not native Budget ledger reads.

---

## 3. Pure Probe vs Publication & Signed-Out Refresh (`V2a`) `[Vesta Client Design]`

### 3.1 `ServerFeatures` Model
```swift
enum ServerFeature: String, Hashable, Codable, Sendable {
    case capabilities = "capabilities"
    case qrLogin = "qr_login"
    case deviceExchange = "device_exchange"
    case calendarInstances = "calendar_instances"
    case budgetNativeRead = "budget_native_read"
}

struct ServerFeatures: Equatable, Sendable {
    let authContract: Int
    let features: Set<ServerFeature>
    let qrOrigin: URL?
    let isLegacy: Bool

    static let legacy = ServerFeatures(authContract: 0, features: [], qrOrigin: nil, isLegacy: true)
    func supports(_ feature: ServerFeature) -> Bool { !isLegacy && features.contains(feature) }
}
```

### 3.2 Pure Probe vs State Publication & `refreshRevision` Rules (Fixing Blocker 2)
- **Pure network probe (`APIClient.probeFeatures(on origin: URL) async throws -> ServerFeatures`):**
  - Side-effect-free! Executes **only** unauthenticated `GET <origin>/api/auth/features` (`no-store`, zero `Authorization`, zero `Cookie`, `0` mutations on `AppState`).
  - Non-200 HTTP (`401`/`403`/`404`/`5xx`), decode error, or `auth_contract < 2` → returns `.legacy`; `URLError` throws so caller decides (`connect()` → `.failed`, foreground → silent no-op).
- **`refreshRevision: Int` rules:**
  - `AppState.beginRefresh(source: RefreshSource) -> Int`: increments `refreshRevision += 1` (and cancels older `activeCapabilitiesRefresh`) on `signOut()`, `saveAndConnect()`, commits, or higher-priority explicit refreshes (`initialAuth`, `foreground`, `userPull`); returns the new `refreshRevision` so callers (such as §7.2 hydration) use that exact revision!
  - Coalesced `.denial` refreshes share the active `refreshRevision` if one is already running.
  - Only a completion matching `(activeOrigin, sessionGeneration, refreshRevision)` may publish `(serverFeatures, capabilities)`.
- **Two publication callers on `AppState`:**
  1. **Signed-out foreground refresh (`phase == .needsAuth`, `enterForeground()`):** Calls `let probe = try await api.probeFeatures(on: snap.origin)`, rechecks `(activeOrigin == snap.origin, sessionGeneration == snap.sGen, refreshRevision == snap.rRev)`, and publishes `serverFeatures = probe` (`capabilities` stays `nil`; `0` authenticated requests before sign-in!). *(QR sign-in in §7.2 calls `api.probeFeatures(on: target)` directly and holds `probe` in a local variable until commit — never touching `AppState.serverFeatures` if redeem fails!)*
  2. **Combined session refresh (`refreshSessionCapabilities(source:revision:)`):**
     - Used on `connect()`, `.ready` `enterForeground()`, `app.refresh()`, `.denial` refresh, and post-commit `.initialAuth` hydration (passing the `revision` returned by `beginRefresh(source: .initialAuth)`).
     - Step 1: Capture `(origin = activeOrigin, sGen = sessionGeneration, rRev = revision)`.
     - Step 2: Run `probe = try await api.probeFeatures(on: origin)` (or reuse the post-confirm local `probe` passed into `.initialAuth` commit!). Recheck `(origin, sGen, rRev)`.
     - Step 3: Pick capabilities endpoint strictly from `probe`:
       - `probe.supports(.capabilities)` → call `GET /api/me/capabilities` bound to `origin` (**never** fall back to `/api/whoami` on `403`/`404`, `Part C §6`).
       - `!probe.supports(.capabilities)` → **skip `/api/me/capabilities`**; call `GET /api/whoami` bound to `origin` and map via `Capabilities.fromLegacyRole`.
     - Step 4: Recheck `(origin, sGen, rRev)` on **both** success and `catch`:
       - **On `200`:** Publish `(serverFeatures = probe, capabilities = resolved)` together in one synchronous `@MainActor` step!
       - **On current-session `401`:** Publish `(serverFeatures = probe, capabilities = nil)`, clear session (`CredentialSessionStore`, `whoami`, `rooms`, `activeCapabilitiesRefresh = nil`), bump generations, and transition to `phase = .needsAuth` (so QR stays visible on saved modern origins!).

### 3.3 Routing Driven by Published `(serverFeatures, capabilities)`
- **QR Sign-In:** `ConnectView` shows **Scan a code from Hestia** on `.unconfigured`, and on `.needsAuth` **only** when `serverFeatures?.supports(.qrLogin) == true` (`Part C §6`).
- **Device Exchange:** Attempt `POST /api/auth/device-token` **only** when `serverFeatures?.supports(.deviceExchange) == true` and (`capabilities?.canUseReceipts == true || nativeBudgetExchangeEligible`).
- **Calendar (`V5`):** `calendarAPI` non-nil iff `serverFeatures?.supports(.calendarInstances) == true && capabilities?.canViewCalendar == true`.
- **Native Budget (`§10.3`):** Default-off unless all 4 gates in §10.3 hold.

### 3.4 V2a Concrete Tests
- `FeaturesProbeTests.testColdLaunchSavedOrigin401PublishesFeaturesWithNilCapabilitiesAndQRVisible`
- `FeaturesProbeTests.testSignedOutForegroundUsesProbeOnlyWithZeroAuthenticatedRequests`
- `FeaturesProbeTests.testFeaturesProbeUnauthenticatedOnLegacy0460Middleware`
- `FeaturesProbeTests.testAdvertisedCapabilities403And404NeverFallBackToWhoami`
- `FeaturesProbeTests.testLatePR3ProbeResponseDiscardedAfterRollbackOrServerSwitch`

---

## 4. Reserved Heading Index Note
*(Sections continue sequentially: §5 V1, §6 V2b, §7 V3, §8 V4, §9 OpenAPI & Decoders, §10 V5 & Native Budget, §11 Re-Review Gates.)*

## 5. V1 Specification (Hestia-Independent, Effort: **M**)

**Goal:** Build and merge the capability model, role-check migration, `403` transitions, discovery-gated SSE startup, and complete fencing **now** against `0.46.0` (`Vesta/openapi.json` stays `0.9.0`).

### 5.1 Explicit Scope Boundaries for V1
- **Stays on `0.9.0`:** `Vesta/openapi.json` untouched; `APIClient.capabilities()` maps `whoami()` via `Capabilities.fromLegacyRole`.
- **Mock injection:** Add `func capabilities() async throws -> Capabilities` to `HestiaAPI`; `MockHestiaAPI` gets `setCapabilities(_:)` and explicit `setAuthOff()` (`WhoAmI(role: nil, user: nil)`).
- **No `CalendarAPI` gate in V1:** Moves to **V5**.
- **No feature probe, Keychain quarantine/migration, or device exchange in V1:** Keeps `TokenStore`, `DeviceTokenStore`, HTTPS password auto-pairing (`pairReceiptsAfterLogin` gated by `capabilities?.canUseReceipts == true`), and `ReceiptPairingView` until **V2a**, **V2b**, and **V4**.

### 5.2 `Capabilities` & Explicit Legacy Auth-Off Set (`Vesta/Models/Capabilities.swift`)
```swift
enum Permission: String, Hashable, Codable, Sendable, CaseIterable {
    case iocView = "ioc.view", iocControl = "ioc.control", iocConfigure = "ioc.configure"
    case calendarView = "calendar.view", calendarEdit = "calendar.edit"
    case systemAuditView = "system.audit.view", systemManageUsers = "system.manage_users"
    case budgetView = "budget.view", budgetEdit = "budget.edit"
    case budgetReceiptsAdd = "budget.receipts.add", budgetReceiptsView = "budget.receipts.view"
    case budgetReceiptsEdit = "budget.receipts.edit", budgetReceiptsMatch = "budget.receipts.match"
    case householdView = "household.view"

    static let deviceEligibleReceiptIDs: Set<Permission> = [
        .budgetReceiptsAdd, .budgetReceiptsView, .budgetReceiptsEdit, .budgetReceiptsMatch,
    ]
    /// Part C §11: device-eligible permissions = {budget.view} ∪ receipt permissions.
    static let deviceEligibleIDs: Set<Permission> = deviceEligibleReceiptIDs.union([.budgetView])

    /// Explicit ordinary installation permissions for legacy auth-off ({user: nil, role: nil}).
    /// Excludes protected `system.manage_users`.
    static let legacyAuthOffInstallation: Set<Permission> = [
        .iocView, .iocControl, .iocConfigure,
        .calendarView, .calendarEdit,
        .systemAuditView,
    ]
}
```
- **Strict scope separation on `Capabilities` (`Part C §11`):**
  - `effectiveDeviceReceiptPermissions = rawReceiptPermissions.intersection(Permission.deviceEligibleReceiptIDs)` (never includes `budget.view`).
  - `effectiveDeviceEligiblePermissions = effectiveDeviceReceiptPermissions.union(ownBudget?.canView == true && ownBudget?.permissions.contains(.budgetView) == true ? [.budgetView] : [])` (used only for rotation ceiling comparison).
  - `canUseReceipts`: `effectiveDeviceReceiptPermissions.contains(.budgetReceiptsAdd)`.
  - `canMatchReceipts`: `effectiveDeviceReceiptPermissions.contains(.budgetReceiptsMatch)`.
  - `canViewIOC`: `isAuthOff || installation.contains(.iocView)`; `canControlIOC`: `isAuthOff || installation.contains(.iocControl)`.
- `Capabilities.fromLegacyRole(role:user:)`: `"viewer"` → `[.iocView, .calendarView, .systemAuditView]`; `"operator"` → viewer + `[.iocControl, .calendarEdit]`; `"admin"` → operator + `[.iocConfigure, .systemManageUsers]` + full `OwnBudget`; `nil` with `user == nil` → `isAuthOff = true`, `installation = Permission.legacyAuthOffInstallation`, `ownBudget = nil`; `nil` with `user != nil` (or unknown string) → fail closed (`[]`, `nil`).

### 5.3 V1 File Inventory
- `Vesta/Models/Capabilities.swift` *(new)*, `Vesta/Models/Units.swift`, `Vesta/Services/HestiaAPI.swift`, `Vesta/Services/APIClient.swift` (`APIError.forbidden`, `mapStatus`, `capabilities()`), `Vesta/Services/EventStream.swift` (yield `.unauthorized`/`.forbidden` before finish), `Vesta/Models/AppState.swift`, `Vesta/VestaApp.swift`, `Vesta/Views/RootView.swift`, `Vesta/Views/HomeView.swift` (`refreshable` → `app.refresh()`, non-IOC state, dismiss `showPairing` & `receiptFlow`), `Vesta/Views/SettingsView.swift` (dismiss `showPairing` at `:101` on `receiptsAPI == nil`), `Vesta/Receipts/{ReceiptsAPI,ReceiptFlow}.swift`, `Vesta/Views/Receipts/ReceiptScanView.swift`, `Vesta/Localizable.xcstrings`.

### 5.4 Exact V1 State Transitions, `applyIOCGrant`, & Discovery Failure Classification

1. **Single Publication Helper — `applyIOCGrant(_ granted: Bool)` (`AppState.swift`):**
   - Called unconditionally after **every** current capability publication to `self.capabilities`, regardless of `RefreshSource` (`.initialAuth`, `.foreground`, `.userPull`, `.denial`), or when clearing capabilities fail-closed.
   - When `granted == false`: unconditionally bump `discoveryGeneration += 1`, cancel and nil `eventTask`, and clear IOC state (`rooms`, `summary`, `globals`, `klima`, `klimaState`). When `granted == true`: leave active state intact so `.initialAuth`/`.foreground`/`.userPull` callers proceed with discovery/stream startup (`.denial` never restarts discovery or SSE).
   - Because every source flows through `applyIOCGrant`, even a `200 OK` `.userPull` (`app.refresh()`) that withdraws `ioc.view` cancels any live `eventTask`, bumps `discoveryGeneration`, clears IOC, and skips `loadDiscovery()`/`startEvents()`.

2. **Discovery-Gated SSE Invariant & Failure Classification (`AppState.swift:350–355`):**
   - **`makeEvents()` (`startEvents()` / reconnect loop) MUST ONLY open after a `loadDiscovery()` snapshot returns `.loaded` (`200 OK`) under the active fence `(sGen == sessionGeneration, cGen == capabilitiesGeneration, dGen == discoveryGeneration, capabilities?.canViewIOC == true)`!**
   - `loadDiscovery()` returns `enum DiscoveryOutcome { case loaded, denied, unauthenticated, transientFailure, cancelledOrStale }`:
     - **`.loaded` (`200 OK` under fence):** Updates IOC state and permits `makeEvents()` stream startup.
     - **`.denied` (`403` `APIError.forbidden`):** **Immediately stops SSE (`break`, `eventTask = nil`, zero stream attempts)**; bumps `discoveryGeneration += 1`, clears IOC state (`rooms`, `summary`, `globals`, `klima`, `klimaState`), sets `app.notice`, keeps **`phase = .ready`** (never `.failed` / `ConnectView`!), and schedules **one** `.denial` refresh (keeping `receiptsAPI` intact). Applies equally during `.connecting` and post-ready snapshots.
     - **`.unauthenticated` (`401` `APIError.unauthorized`):** **Stops SSE immediately (`break`, `eventTask = nil`, zero stream attempts)**; clears session, bumps generations, transitions to `.needsAuth`.
     - **`.cancelledOrStale` (`CancellationError` / `Task.isCancelled` / fence mismatch):** **Stops SSE immediately (`break`, zero stream attempts).**
     - **`.transientFailure` (`URLError` / HTTP `5xx` other than `401`/`403`):** During `.initialAuth` `.connecting` or non-403 control, surfaces `.failed(...)`; inside the SSE reconnect backoff loop (`startEvents()`), **never opens `makeEvents()`**, keeps the loop alive, backs off (`1s..30s`), and retries `loadDiscovery()` until `.loaded` or a stop condition (`.denied` / `.unauthenticated` / `.cancelledOrStale`).

3. **`capabilities()` `403` at Initial Auth vs Signed-In Refresh:**
   - **Initial `connect()` / `login()` (`phase == .connecting`):** `403` sets `phase = .failed(.forbidden)`.
   - **Signed-in refresh (`phase == .ready`):** `403` stays `phase = .ready`, sets `app.notice`, never recurses, and clears capabilities fail-closed via `applyIOCGrant(false)` + hides receipts.

4. **Full IOC Lifecycle (`AppState.swift:197`, preserving `testForegroundResyncsSnapshot`):**
   Tag coalesced `refreshCapabilities(source: RefreshSource)` with `enum RefreshSource { case initialAuth, foreground, userPull, denial }`, each invoking `applyIOCGrant(published.canViewIOC)` after publishing `capabilities`:
   - **`enterBackground()`:** `eventTask?.cancel(); eventTask = nil` (grant stays `true`).
   - **`connect()` / `login()` (`.initialAuth`):** After `applyIOCGrant(canViewIOC)`: if `canViewIOC`, `if case .loaded = await loadDiscovery(), fenceHolds { startEvents(skipInitialDiscovery: false) }` (where `startEvents()` starts with `loadDiscovery()`, preserving the 2-snapshot sequence expected by `AppStateTests.testForegroundResyncsSnapshot`!). If `!canViewIOC`: set `phase = .ready` with zero `discovery()`/`makeEvents()`.
   - **`enterForeground()` (when `phase == .ready`):** Runs `refreshCapabilities(source: .foreground)` (even when `canViewIOC == false`), which calls `applyIOCGrant(published.canViewIOC)`. If fence holds and `canViewIOC == true`, clears IOC denial `notice` and calls `startEvents()` (runs `loadDiscovery()` → opens `makeEvents()` only on `.loaded`; stops on `.denied`/`.unauthenticated`/`.cancelledOrStale`; backs off without stream on `.transientFailure`).
   - **`HomeView.refreshable` → `await app.refresh()` (`.userPull`, `phase == .ready`):** Runs `refreshCapabilities(source: .userPull)` → calls `applyIOCGrant(published.canViewIOC)`. Only if fence holds and `canViewIOC == true` does it run `guard case .loaded = await loadDiscovery(), fenceHolds else { return }` and restart a missing stream (`if eventTask == nil { startEvents(openImmediatelyAfterSnapshot: true) }`).
   - **Denial-triggered refresh (`.denial`):** Triggered by `403` on controls, `discovery()`, SSE `.forbidden`, or `ReceiptError.forbidden`. Calls `applyIOCGrant(published.canViewIOC)` and **NEVER** starts `loadDiscovery()` or `startEvents()`.

5. **Controls, SSE `.forbidden` & Error Fencing:**
   - Control/scene/IR/thermostat `403` → stays `.ready`, sets `notice`, zero write retries, one `.denial` refresh.
   - SSE `.forbidden` (`403`) → stops `eventTask` (`= nil`, zero reconnect loop!), bumps `discoveryGeneration`, clears IOC state, sets `notice`, one `.denial` refresh.
   - Fence **both** success and `catch` paths with `(sGen, cGen, dGen)`; on `signOut()`, `saveAndConnect()`, and `401`, cancel and nil `activeCapabilitiesRefresh`.
   - Dismiss `showPairing` & `receiptFlow` in both `HomeView` and `SettingsView` on `receiptsAPI == nil`; clear `candidates`/`form.candidate` on match loss; migrate `loadDiscovery()`-first tests (`AppStateTests.swift:142`) to establish IOC capability via `connect()`/`login()` first.

### 5.5 V1 Concrete Test Names
- `CapabilitiesTests.testLegacyAuthOffExcludesManageUsersAndSeparatesBudgetViewFromReceipts`
- `APIClientTests.testMapStatusSeparates401From403`
- `AppStateTests.testForegroundResyncsSnapshot` *(preserved)*
- `AppStateTests.testRepeatedDiscovery403ProducesZeroSSEStreamStartsAndClearsIOC`
- `AppStateTests.testPostReadyDiscovery403StopsExistingSSEAndClearsIOC`
- `AppStateTests.testCapabilityRefreshLossOfIOCViewStopsSSEAndClearsIOC`
- `AppStateTests.testLiveStreamFollowedByUserPullWithdrawingIOCGrantCancelsSSEAndClearsIOC`
- `AppStateTests.testDiscoveryTransientFailureBacksOffWithoutStreamWhile401Or403OrCancelStopsLoop`
- `AppStateTests.testInitialConnectCapabilities403FailsAndFirstDiscovery403TransitionsToReady`
- `AppStateTests.testPullToRefreshWithUnchangedGrantReloadsDiscoveryAndRestartsMissingStream`
- `AppStateTests.testDenialTriggeredRefreshDoesNotImmediatelyReopenDiscoveryOrSSE`
- `AppStateTests.testSSEDenial403StopsWithoutReconnectLoopAnd401LogsOut`
- `AppStateTests.testPausedOldRequestLate401And403CannotMutateNewerSession`
- `ReceiptTests.testMatchLossClearsOpenReviewCandidatesAndFormSelection`
- `HomeAndSettingsTests.testPairingSheetsDismissWhenReceiptsWithdrawn`

---

## 6. V2b — Single Authoritative Session Record, Publication Owner & Scoped Credentials (`L`)

- **Hestia dependency:** None (`Part C §§7–8` model; `prior_token` remote call activates in **V4**).
- **Files:** `Vesta/Config/BackendURLStore.swift` (`OriginMatcher`, `OverrideRecord`), `Vesta/Services/CredentialSessionStore.swift` *(new)*, `Vesta/Services/TokenStore.swift`, `Vesta/Services/DeviceTokenStore.swift`, `Vesta/Services/BearerAuthMiddleware.swift`, `Vesta/Services/APIClient.swift`, `Vesta/Services/EventStream.swift`, `Vesta/Receipts/ReceiptPairing.swift`, `Vesta/Models/AppState.swift`, `VestaTests/BackendURLStoreTests.swift`, `VestaTests/InfraTests.swift`, `VestaTests/DevicePairingTests.swift`, `VestaTests/APIClientTests.swift`.

### 6.1 Single Authoritative Session Record & Single Publication Owner (Fixing Blocker 3)
- **Single publication owner:** `@MainActor` (`AppState`) exclusively owns local session publication through **`CredentialSessionStore: @unchecked Sendable`** (backed by `OSAllocatedUnfairLock<BoundSession?>`, matching `BackendURLStore`, so `@MainActor` publication takes **zero `await`s** while `APIClient`, `BearerAuthMiddleware`, and `EventStream` read immutable `BoundSession` snapshots synchronously!).
  - `APIClient.login(user:password:on origin: URL)` returns `(user, token)` without writing Keychain.
  - Every authenticated REST call snapshots `let session = sessionStore.currentSnapshot()` and enforces `OriginMatcher.matches(baseURL, session.origin)`.
  - `APIClient.remoteLogout(token: String, origin: URL)` is stateless and never mutates `CredentialSessionStore` or Keychain.
- **ONE Authoritative Persisted Session Record (no multi-key stage juggling):**
  Store **one** JSON record under Keychain `account = "backend-session"` (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`):
  ```swift
  struct AuthoritativeSessionRecord: Codable, Equatable, Sendable {
      let commitID: UUID
      let origin: URL
      let actor: String?
      let token: String
  }
  ```
  `BackendURLStore` persists `OverrideRecord { urlString: String, sessionCommitID: UUID? }` (backward-readable from `1.x` raw URL string with `sessionCommitID: nil`):
  1. **Atomic Commit (`login` / `loginWithQR`):**
     - Generate `let commitID = UUID()`.
     - **Single atomic `SecItemUpdate` / `SecItemAdd` write FIRST:** Persist `AuthoritativeSessionRecord(commitID: commitID, origin: target, actor: user, token: token)`. If this write fails (`.locked`/`.writeFailed`), **abort immediately before touching `BackendURLStore` or in-memory state** — previous Keychain record, `BackendURLStore` override, and session stay 100% intact!
     - **Update derived `BackendURLStore` override + lock:** Save `OverrideRecord(urlString: target.absoluteString, sessionCommitID: commitID)` and publish `BoundSession` under `CredentialSessionStore` lock.
  2. **Restart Reconciliation on `bootstrap()`:**
     - Read `record = Keychain.loadAuthoritativeSession()` and `override = BackendURLStore.loadOverrideRecord()`.
     - **If `record != nil` and `override?.sessionCommitID != record.commitID`:** Process death interrupted between atomic Keychain commit and `BackendURLStore` update (covers **both** changed-origin AND **same-origin account switches**, because `commitID` differs!). **`AuthoritativeSessionRecord` is authoritative:** re-derive `BackendURLStore` from `record` (`OverrideRecord(urlString: record.origin.absoluteString, sessionCommitID: record.commitID)`)!
       - Same-origin account switch crash → `record` already holds `(origin: A, actor: user2, token: tok2, commitID: c2)`; `BackendURLStore` updates to `c2`, and `user1`'s device token is excluded because `token.actor != user2`!
       - Changed-origin crash → `BackendURLStore` updates to `record.origin`, never leaking `record.token` to the old origin!
     - **If `override?.sessionCommitID != nil` and `record == nil`:** Signed-out crash during `signOut()`/`saveAndConnect()` — clear `sessionCommitID = nil` on `override` and stay `.needsAuth` on `override.url`.
     - **One-way `1.x` legacy `"backend"` upgrade (`TokenStore.swift:7`, durable marker `"backend-legacy-migrated"`):**
       - Persist a one-way Keychain marker `account = "backend-legacy-migrated"` (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, surviving `signOut()` and `saveAndConnect(_:)`).
       - **Invariant on every launch (`bootstrap()`):** If `"backend-session" != nil` OR `"backend-legacy-migrated"` exists in Keychain, unconditionally delete any leftover raw `"backend"` item and **never** re-read or re-migrate it (prevents resurrection if a crash interrupted between writing `"backend-session"` and deleting `"backend"`).
       - Only when `"backend-session" == nil` AND `"backend-legacy-migrated"` is absent may `bootstrap()` check raw `"backend"`: if `hasOverride()`, verify raw token on `savedOverride` only, write `"backend-legacy-migrated"` + `AuthoritativeSessionRecord`, update `OverrideRecord` with `commitID`, and delete old `"backend"`; if `!hasOverride()`, write `"backend-legacy-migrated"` and delete orphan `"backend"`.
  - **Explicit `signOut()` & manual `saveAndConnect(_ raw:)` (snapshot before clearing, delete both):**
    1. **Capture an immutable `CleanupSnapshot` first** (before mutating Keychain or `BackendURLStore`): extract `oldSession` from `AuthoritativeSessionRecord`, OR (if an un-migrated `1.x` install has not yet upgraded) from legacy `"backend"` + `savedOverride`, plus `detachedDevice`.
    2. Write `"backend-legacy-migrated"`, delete **both** `"backend-session"` **and** legacy `"backend"` from Keychain (`try` — if Keychain `.locked`, abort/surface storage failure before modifying `BackendURLStore` override!).
    3. Update `BackendURLStore` (`saveOverride(url, sessionCommitID: nil)` on switch; clear `sessionCommitID = nil` keeping `url` on `signOut()`).
    4. Pass the immutable `CleanupSnapshot` into `resetTask` for best-effort detached `remoteLogout` / `revoke`.

### 6.2 `(origin, actor, owner_key)` Device Store, `provenance` Default & Legacy Rules
```swift
enum DeviceTokenProvenance: String, Codable, Equatable, Sendable {
    case exchanged, legacyPasswordLogin, legacyCodeRedeem, legacyMigrated1x
}

struct StoredReceiptDeviceToken: Codable, Equatable, Sendable {
    let server: URL
    let provenance: DeviceTokenProvenance
    let actor: String?
    let owner: String?
    let ownerKey: String?
    let issuedPermissions: [String]?
    let lastUsableCeiling: [String]?
    let credential: ReceiptDeviceToken

    init(from decoder: any Decoder) throws {
        // ... standard fields ...
        provenance = try c.decodeIfPresent(DeviceTokenProvenance.self, forKey: .provenance) ?? .legacyMigrated1x
        // ... optional actor, owner, ownerKey, issuedPermissions, lastUsableCeiling ...
    }
}
```
- **Decoder default:** Missing `"provenance"` on existing `1.x` active and `pendingRevocations` records decodes safely as `.legacyMigrated1x`.
- **`.legacyCodeRedeem` provenance:** `device-token/redeem` returns no actor/owner; store `provenance: .legacyCodeRedeem` (`actor: nil, owner: nil`) without stamping `currentUser`; usable on matching origin for that session on legacy servers and cleared on `signOut()`, server switch, or user change.
  - Saving the same origin keeps a Keychain handoff from the prior verified session. A successful login for the same actor at that origin rebinds the code credential to the new commit ID. The previous commit ID stays valid until the authoritative session write succeeds. Sign-out, a different origin, or a different actor stages the full credential for revocation before changing the session. Recovery finishes a staged detach once the old credential has no current session binding.
- **Exchanged `(origin, actor, owner_key)` lookup:** Latest `200` from `POST /api/auth/device-token` establishes active `ownerKey` for `(origin, actor)`. Legacy `1.x` self-owner tokens migrate via `prior_token` (`Part C §8`, `actor == owner` only) in `V4` and stay quarantined (exact-ID self-revoke only) on legacy servers.

### 6.3 V2b Concrete Tests
- `CredentialSessionStoreTests.testSingleRecordKeychainWriteFailureHappensBeforeOverrideChangeAndKeepsPrior`
- `CredentialSessionStoreTests.testSameOriginAccountSwitchCrashReconcilesCommitIDAndIsolatesPriorUsersDeviceToken`
- `CredentialSessionStoreTests.testChangedOriginCrashDerivesBackendURLFromAuthoritativeKeychainRecord`
- `CredentialSessionStoreTests.testManualSaveAndConnectKeychainLockedAbortsBeforeOverrideChange`
- `CredentialSessionStoreTests.testInterruptionAfterAuthoritativeWriteThenSignOutNeverResurrectsLegacyToken`
- `CredentialSessionStoreTests.testInterruptionAfterAuthoritativeWriteThenChangedOriginSwitchNeverSendsLegacyBearer`
- `DevicePairingTests.testMissingProvenanceDecodesAsLegacyMigrated1xOnActiveAndPendingRecords`
- `APIClientTests.testImmutableBoundSessionAndSSESnapshotIgnoreMutatedDefaults`

---

## 7. V3 — QR Sign-In & Unified Concurrency/Commit Order (`L`)

- **Hestia dependency:** Hestia PR 3 (`features ∋ "qr_login"`, `POST /api/auth/qr-redeem`, `Part A QR sign-in`, `Part C §§3, 5, 6`).
- **Files:** `Vesta/openapi.json`, `Vesta/Models/QRLoginPayload.swift` *(new)*, `Vesta/Services/QRLoginAPI.swift` *(new)*, `Vesta/Services/APIClient.swift`, `Vesta/Models/AppState.swift`, `Vesta/Views/Components/QRScannerView.swift` *(new)*, `Vesta/Views/Receipts/ReceiptPairingView.swift`, `Vesta/Views/ConnectView.swift`, `Vesta/Info.plist`, `Vesta/InfoPlist.xcstrings`, `Vesta/Localizable.xcstrings`, `project.yml`, `VestaTests/QRLoginTests.swift` *(new)*, `VestaTests/AppStateTests.swift`, `VestaTests/InfraTests.swift`.
- **OpenAPI subset to pin:** `qrRedeem` (`POST /api/auth/qr-redeem`).

### 7.1 Scanner UI, Raw-Authority Validation & Isolated Transport
- Shared `QRScannerView` (**VisionKit `DataScannerViewController`**). `ConnectView` shows **Scan a code from Hestia** on `.unconfigured`, and on `.needsAuth` only when `serverFeatures?.supports(.qrLogin) == true`, with camera-denied **Open Settings** CTA and 45-locale strings (`InfoPlist.xcstrings`, `Localizable.xcstrings`).
- **`QRLoginPayload` raw validation (before `URLComponents`/`URL`):** reject `>78` bytes, whitespace, control/non-ASCII chars, `\`, `%`, `?`; exact `"hestia-login:"`; split `#` into `(rawOrigin, rawCode)`; `rawCode` 19-char canonical base64url (decode 14 bytes + exact re-encode match); `rawOrigin <= 45` bytes starting `"https://"`, reject `@`/`/`/`\`/`?`/`#`/`%`, validate bracketed IPv6 (`inet_pton`) or hostname/IPv4 labels + valid port (`1...65535`, no leading `0`, non-empty), canonicalize lowercase host & omit `:443`.
- **Confirmation & Isolated Transport:** Immutable `PendingQRScan` prompt when `!hasOverride()` or origin mismatch (**zero requests before confirm**). Ephemeral `URLSession` (`no cookies`, `urlCredentialStorage = nil`, `willPerformHTTPRedirection → nil`, HTTP Basic/Digest auth challenges cancelled in `didReceive challenge`), sanitized errors/logs.

### 7.2 Unified Commit Order, Local Probe Hold, Sign-Out & Manual Switch (Fixing Blocker 2 & Blocker 3)
1. **QR attempt fence starts BEFORE feature probe:** On user confirm (or auto-connect match), capture **before the first `await`**: `(attemptID = nextAuthAttempt(), preflightGen = sessionGeneration, target = payload.origin)`. Await `resetTask?.value` if active, recheck fence.
2. **Pure post-confirm probe (held locally, ZERO mutation to `AppState.serverFeatures`!):** Call `let probe = try await api.probeFeatures(on: target)`. Recheck fence (`attemptID == currentAuthAttempt && preflightGen == sessionGeneration`)! If `!probe.supports(.qrLogin)` or `probe.qrOrigin != target`, fail cleanly **before spending the code** (leaving previous origin, `serverFeatures`, and `capabilities` untouched!).
3. **Redeem & validate:** Call `QRLoginAPI.redeem(origin: target, code: payload.code)` (or `APIClient.login` for password path). Validate `result.ok == true && !result.user.isEmpty && !result.token.isEmpty`. On failure/cancel: return immediately leaving previous origin, `serverFeatures`, `capabilities`, and session intact! Recheck fence before committing.
4. **Atomic `@MainActor` Commit (`CredentialSessionStore`, zero `await`s):**
   1) Snapshot `oldSession = credentialSessionStore.currentSnapshot()` and `oldDevice = receiptPairing.currentActiveToken()`.
   2) Run `try credentialSessionStore.commitAuthoritative(origin: target, actor: result.user, token: result.token)` (atomic Keychain write FIRST → `BackendURLStore` `OverrideRecord`). On Keychain failure, abort keeping old connection intact!
   3) Advance `sessionGeneration += 1`, `capabilitiesGeneration += 1`, `discoveryGeneration += 1`; cancel `eventTask`; set `serverFeatures = probe`, clear `whoami`/`capabilities`/`rooms`/globals.
   4) **Detach ONLY if origin or user changed:** `let detachedDevice = shouldDetach(oldDevice, targetOrigin: target, newUser: result.user) ? receiptPairing.detachActive() : nil`.
   5) **Detached remote cleanup:** If `detachedDevice != nil`, revoke using full `detachedDevice.credential` against **`detachedDevice.server`**; if `oldSession != nil && (!OriginMatcher.matches(oldSession.origin, target) || oldSession.actor != result.user)`, call stateless `api.remoteLogout(token: oldSession.token, origin: oldSession.origin)`.
   6) **Hydrate using `beginRefresh` revision:** `let hydrationRev = beginRefresh(source: .initialAuth)` (advances `refreshRevision` and resets `activeCapabilitiesRefresh`); set `phase = .connecting`, pass `hydrationRev` to `refreshSessionCapabilities(source: .initialAuth, revision: hydrationRev, preloadedProbe: probe)`, recheck `(commitGen == sessionGeneration, hydrationRev == refreshRevision)` before `loadDiscovery()`/`startEvents()` and `phase = .ready`.
- **Local `signOut()` & Manual `saveAndConnect(_ raw:)` (`AppState.swift:130`):** First capture an immutable `CleanupSnapshot` (`oldSession` from `"backend-session"` or un-migrated `"backend"` + `detachedDevice`), then write `"backend-legacy-migrated"` and delete **both** Keychain `"backend-session"` and legacy `"backend"` first, update `BackendURLStore` + `CredentialSessionStore` lock, advance all generations + `refreshRevision`, cancel/nil `activeCapabilitiesRefresh` + `eventTask`, clear UI state **synchronously on `@MainActor`**, then spawn `resetTask` for stateless `remoteLogout` / `revoke` against old origins from the immutable snapshot (and `connect()` guarded by `commitGen == sessionGeneration`).

### 7.3 V3 Concrete Tests
- `QRLoginTests.testSharedHestiaAuthorityCanonicalizationAndRejectFixtures`
- `QRLoginTests.testIsolatedTransportRejectsCookiesCredentialsRedirectsAndHTTPAuthChallenge`
- `QRLoginTests.testZeroRequestsBeforeConfirmation`
- `AppStateTests.testQRConfirmThenFailedRedeemLeavesPreviousOriginFeaturesAndCapabilitiesIntact`
- `AppStateTests.testQRSignOutDuringFeatureProbeDoesNotSpendCode`
- `AppStateTests.testResetPausedBeforeRemoteLogoutPreservesNewQRToken`
- `AppStateTests.testCompetingPasswordAndQRLoginCommitsLatestWinner`
- `AppStateTests.testQRSameOriginSameUserRetainsDeviceTokenWithoutRevoke`
- `AppStateTests.testQRInvalidOkOrEmptyTokenAbortsCommit`

---

## 8. V4 — Split Decision Table & 4-State Rotation Journal (`L`)

- **Hestia dependency:** Hestia PR 3 (`features ∋ "device_exchange"`, `POST /api/auth/device-token`, `Part C §§2–8, 10–11`).
- **Files:** `Vesta/openapi.json`, `Vesta/Services/DevicePairingAPI.swift`, `Vesta/Services/BearerAuthMiddleware.swift`, `Vesta/Services/ExplicitNullsMiddleware.swift`, `Vesta/Receipts/{ReceiptPairing,ReceiptsAPI,ReceiptFlow}.swift`, `Vesta/Models/AppState.swift`, `Vesta/Views/SettingsView.swift`, `Vesta/Views/Receipts/{ReceiptPairingView,ReceiptScanView}.swift`, `Vesta/Localizable.xcstrings`, `PRIVACY.md`, `VestaTests/{DevicePairingTests,ReceiptTests,ReceiptFlowRaceTests,AppStateTests}.swift`.
- **OpenAPI subset to pin:** `issueAuthDeviceToken` (`POST /api/auth/device-token`, `scope: "receipts" | "device"`, `owner_key`, `409 device_token_prior_invalid`) and PR 3 capability schemas.

### 8.1 Split Device-Exchange Decision Table (`Part C §§10–11`, Fixing Blocker 4)

All exchange calls run **only** when `serverFeatures?.supports(.deviceExchange) == true`:

#### A. Proof-Bearing Rotation (`with prior_token`, captured `capturedActor`, `expectedOwnerKey`, `priorTokenID`)
| Outcome | Validation & Action on Stored Token | Follow-Up |
|---|---|---|
| **`200 OK`** | **Validate:** `resp.actor == capturedActor` AND (`expectedOwnerKey == nil` ? `resp.actor == resp.owner && !resp.owner_key.isEmpty` : `resp.owner_key == expectedOwnerKey`) AND `resp.token_id == priorTokenID`. | **If valid:** write `.replaced` in journal → promote to `"receipts"` (`lastUsableCeiling = issued_permissions ∩ Permission.deviceEligibleIDs`) → delete journal. **If ANY check fails (anomaly!):** quarantine `resp` credential, keep `priorToken` unchanged, do not overwrite active slot. |
| **`409 device_token_prior_invalid`** (`Part C §10`) | **ONLY code permitting local drop of `priorToken`!** Retain `(oldToken = priorToken, oldOrigin = journal.server)` in memory; clear active slot & journal. | Immediately transition to **Table B (Fresh Issuance)**; if fresh `200` succeeds, best-effort `DevicePairingAPI.revoke(oldToken, server: oldOrigin)` (requires full bearer + origin, `DevicePairingAPI.swift:137`). |
| **`401`** or **`403 budget_forbidden`** *(during initial `.intent`/`.sent`)* | **Keep `priorToken` active & unchanged; NEVER revoke.** | Delete journal (`intent`/`sent`); `401` → keep `.ready`, prompt re-sign-in; `403` → one `.denial` refresh. |
| **`401`** or **`403 budget_forbidden`** *(during retry from `.outcomeUnknown`)* | **Do NOT delete journal and do NOT clear quarantine!** Keep `state = .outcomeUnknown` and `priorToken` quarantined across this denial and restarts (`NEVER revoke`). | Surface auth/permission prompt (`401` → prompt re-sign-in; `403` → one `.denial` refresh) and retain retry responsibility until **only** verified `200` (matching `token_id`, `actor`, `owner_key`) or `409 prior_invalid` resolves `.outcomeUnknown`. |
| **Timeout / `5xx` / crash in `.sent`** | Transition journal to **`.outcomeUnknown`**; quarantine `priorToken` out of active use (**never** delete or overwrite). | Retry `POST /api/auth/device-token` with **same `prior_token`** on next authenticated foreground/pair tap (only when session `(origin, actor, slot)` matches): `200` matching `token_id`/`actor`/`owner_key` = success (promote); `409 prior_invalid` = transition to Table B fresh issuance + best-effort revoke of `oldToken` at `oldOrigin`; `401`/`403` = stay in `.outcomeUnknown` + keep `priorToken` quarantined; `409 device_token_limit_reached` = stop retrying and guide user (role-aware) with preserved device-identifying info. |

#### B. Fresh Issuance (`no prior_token`)
| Outcome | Action | Follow-Up |
|---|---|---|
| **`200 OK`** | Establish `(origin, actor, owner_key)` as active slot (`lastUsableCeiling = issued_permissions ∩ Permission.deviceEligibleIDs`). | If replacing an older distinct slot whose secret is still held (`oldToken`), best-effort `revoke(oldToken, server: oldOrigin)`. |
| **`409 device_token_limit_reached`** | Active slot remains unchanged/unpaired; stop automatic retries. | Surface `DevicePairingError.deviceLimit` (5-slot cap), preserving device-identifying info (`deviceName` / `token_id` where known): direct **owners** to hestia's device list, and direct **delegates** to the **ledger owner** (browser device administration is owner-only, `hestia/budget/device_token.py:582`). |
| **`401` / `403 budget_forbidden` / Network** | Active slot remains unpaired/unchanged. | `401` → keep `.ready`, prompt re-sign-in; `403` → one `.denial` refresh. |

#### C. Runtime Receipt / Budget API Outcomes
- **Runtime `403`:** Run **one** `.denial` `refreshSessionCapabilities()` first: if grants removed → clear/hide surface; if `lastUsableCeiling < effectiveDeviceEligiblePermissions` (`deviceEligibleIDs` only) → enter Table A (`with prior_token`).
- **Runtime `401 device_token_revoked` / `device_token_expired`:** Drop active slot; refresh capabilities once; if still eligible (e.g. Owner A → B reassignment), enter Table B (Fresh Issuance).
- **Runtime `401 device_token_invalid` (PR 3 → PR 2 rollback):** Move exchanged token to separate `rollbackQuarantine` store (never `pendingRevocations` against PR 2); re-probe `features`; allow owner legacy pairing on PR 2.

### 8.2 Persisted 4-State Rotation Journal & Recovery (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
Store `RotationJournalRecord { state: intent | sent | outcomeUnknown | replaced, server, capturedActor, expectedOwnerKey, slotTokenID, priorToken, priorProvenance, replacement?, updatedAt }` under Keychain `account = "receipts-rotation-journal"`:
1. Write `.intent` before starting; advance to `.sent` immediately before sending HTTP request.
2. **Active Session-Match Guard before Retry or `.replaced` Promotion (`bootstrap()` / `refreshStatus()` / retry):** Verify `OriginMatcher.matches(journal.server, activeOrigin) && journal.capturedActor == currentUser` and that `journal.slotTokenID` matches the active/quarantined slot (`expectedOwnerKey` when present). If origin, actor, or slot mismatches the current active session, **do not** retry with `prior_token` or promote `journal.replacement` into the wrong session (abort/isolate without mutating the active session's slot).
3. **Restart recovery (`bootstrap()`/`refreshStatus()` once session-match holds):**
   - **`.intent`** (pre-send death): delete journal, **keep `priorToken` active & unchanged** (request never left phone).
   - **`.sent`** (crashed mid-HTTP): promote to **`.outcomeUnknown`**, quarantine `priorToken` from active receipt calls, and schedule Table A retry with same `prior_token`.
   - **`.outcomeUnknown`**: keep `priorToken` quarantined across restarts and across any `401`/`403` denial until **only** verified `200` (same `token_id`, `actor`, `owner_key`) or `409 device_token_prior_invalid` resolves `.outcomeUnknown` / deletes the journal.
   - **`.replaced`**: promote `journal.replacement` to `"receipts"` and delete journal.
   - *(Death after explicit `401`/`403` during initial `.intent`/`.sent` deletes journal synchronously so `priorToken` stays active & unchanged; death after `401`/`403` from `.outcomeUnknown` keeps `.outcomeUnknown` and `priorToken` quarantine intact!)*
- **Ceiling & Scope:** `lastUsableCeiling` compares `Permission.deviceEligibleIDs` (`{budget.view}` ∪ `receipts.*`); `budget.view` never grants receipt access (`canUseReceipts` requires `budget.receipts.add`).
- **Pending revocations:** Drop **only** on `200`, `401 device_token_expired`, or `401 device_token_revoked`; keep on bare `404`, `budget_receipts_disabled`, `401 device_token_invalid`, `503`, and network errors; `hasEvictedPendingRevocations` preserves notice on 5-entry overflow.
- **Per-operation `ReceiptSessionScope`:** Capture `ReceiptSessionScope(origin, actor, ownerKey, credential)` at `ReceiptFlow` creation and on each `ReceiptDraftJanitor.Item`; pass `scope` to every `ReceiptsAPI` call and revalidate after every `await`; `409 already_submitted` clears `parsed` without retry/delete.

### 8.3 V4 Concrete Tests
- `DevicePairingTests.testPreSendDeathOnIntentJournalKeepsPriorTokenActive`
- `DevicePairingTests.testLostSuccessTimeoutSetsOutcomeUnknownQuarantinesPriorAndResolvesOnRetry`
- `DevicePairingTests.testLostSuccessOutcomeUnknownFollowedBy401Or403PersistsJournalAndQuarantineAcrossRestart`
- `DevicePairingTests.testOutcomeUnknownJournalWithMismatchedOriginOrActorDoesNotRetryOrPromoteWrongSession`
- `DevicePairingTests.testFull5SlotSetStopsRetryingAndPreservesDeviceIdentifyingInfo`
- `DevicePairingTests.testDeathAfter401Or403ClearsJournalAndKeepsPriorTokenUnchanged`
- `DevicePairingTests.testProofBearing200AnomalyActorOwnerKeyOrTokenIDMismatchQuarantinesNewAndKeepsOld`
- `DevicePairingTests.testPriorToken409PriorInvalidFreshExchangeAndRevokesOldWithFullBearerAndOrigin`
- `DevicePairingTests.testDeviceEligibleCeilingTracksBudgetViewSeparatelyFromReceiptAccess`
- `DevicePairingTests.testRollbackQuarantineSeparatesPR3TokenFromLegacySlot`
- `ReceiptFlowRaceTests.testInFlightReceiptOpsUseCapturedScopeAfterAccountSwitch`
- `ReceiptTests.test409AlreadySubmittedAndLegacyLinkNullConfirm`

---

## 9. Hand-Pinned OpenAPI Subset & Dual `0.9.0` Decoder Suites (`V2a`, `V3`, `V4`, `V5`)

1. Normalize full hestia spec outside repo: `python3 scripts/normalize_openapi.py ../hestia/docs/api/openapi.json build/hestia-normalized.json`.
2. Subset-merge only target `operationId`s (paths + transitive `$ref` closure under `components.schemas`) into `Vesta/openapi.json`, keeping `/api/users` (`UserRow.role`) intact.
3. **Dual pinned `0.9.0` generated Swift decoder suites:**
   - **`Legacy110ContractTests`** (`v1.1.0:Vesta/openapi.json` + `v1.1.0:Vesta/openapi-generator-config.yaml`, includes `UserRow`, 0 receipt paths): decodes recorded PR 2/PR 3 responses for `POST /api/login` (`bearer: true`), `GET /api/whoami` (`viewer`/`operator`/`admin`/auth-off), `GET /api/users` (required `UserRow.role`), `GET /api/discovery`, and `POST /api/control`/`/api/scene`/`/api/ir`.
   - **`LegacyReceipts090ContractTests`** (`dd5df46:Vesta/openapi.json` + `dd5df46:Vesta/openapi-generator-config.yaml`, includes all 6 legacy receipt paths): decodes recorded PR 2/PR 3 responses for `device-token/{login,redeem,revoke}` and `receipts/{parse-text,confirm,delete}`.

---

## 10. V5 — Calendar Agenda (`0.48.0`), Release Gates (`2.0.0`) & Native Budget (`§10.3`)

### 10.1 V5 — Calendar Integration (`M`)
- **Contract note:** the calendar shipped as hestia OpenAPI `0.48.0` (merge `969c4b0`); `0.47.0` went to an unrelated Gmail change. PR #17 pins that subset now and keeps the entry point behind `AppState.nativeCalendarEnabled` (default `false`) plus `canViewCalendar`; V2a replaces the flag with `serverFeatures?.supports(.calendarInstances)`.
- **Hestia dependency:** Hestia `0.48.0` (`features ∋ "calendar_instances"`, `GET /api/calendars/instances`, `Part C §9`) + PR 3.
- **Files:** `Vesta/openapi.json`, `Vesta/Calendar/*`, `Vesta/Services/APIClient+Calendar.swift` *(new)*, `Vesta/Models/AppState.swift`, `Vesta/Views/HomeView.swift`, `Vesta/Views/Calendar/AgendaView.swift`, `Vesta/Localizable.xcstrings`, `project.yml`, `VestaTests/AgendaTests.swift`.
- **Behavior:** Gate `AppState.calendarAPI` on `serverFeatures?.supports(.calendarInstances) == true && capabilities?.canViewCalendar == true`. Adapter maps server `instance_id` → `AgendaOccurrence.id` and sends `tz: calendar.timeZone.identifier`. Keep `200 {enabled: false}` → `AgendaStore.State.disabled`. On `403`, feature removal, or sign-out/switch while `AgendaView` is open, clear `state`/`groups`, discard late responses via `(sessionGen, capabilitiesGen, features)`, run one coalesced `.denial` refresh on `403`, and close/disable the sheet without affecting IOC/Receipts.
- **Tests:** `AgendaTests.testAdapterUsesServerInstanceID`, `AgendaTests.test200EnabledFalseShowsDisabled`, `AgendaTests.testOpenAgendaDiscardsDataAndLateResponsesOn403FeatureLossOrSwitch`.

### 10.2 `2.0.0` Release Gates
- [ ] **CI & Dual Legacy Decoders:** `make test` + `make coverage` green (V1–V5 + `Legacy110ContractTests` + `LegacyReceipts090ContractTests` + `PrivacyLocalizationTests` + 45-locale `CatalogCompletenessTests`); `PRIVACY.md` updated.
- [ ] **Version Bump & TestFlight:** `MARKETING_VERSION: "2.0.0"`, bump `CURRENT_PROJECT_VERSION` in `project.yml`; TestFlight build via `ci_scripts/ci_post_clone.sh`.
- [ ] **Gate 1 — `0.46.0` Compatibility:** `features` non-200 → `whoami.role`; password login, IOC, viewer read-only, admin legacy receipts pass; **zero** native Budget reads.
- [ ] **Gate 2 — PR 3 / `0.48.0` Owner & Delegate UAT:** Owner QR sign-in, IOC, Calendar (`0.48.0`), full receipt match, `1.x` `prior_token` migration (`token_id` preserved); delegate submits attributed receipt without match picker; non-IOC `.ready`; foreground widening rotation.
- [ ] **Gate 3 — Populated PR 3 → PR 2 Rollback Run:** Point `2.0.0` at PR 2 rollback server (`features = ["capabilities"]`): `GET /api/me/capabilities` (`200`), IOC + browser-only `own_budget` metadata stay decoupled from native ledger (**zero** native `/api/budget/*` read calls), PR 3 token moves to `rollbackQuarantine` on `401 device_token_invalid`, self-owner pairs via legacy fallback, delegate hides receipts.
- [ ] **Gate 4 — Installed `1.1.0` (`0.9.0`) Gate Before Hestia PR 4:** Verify household `1.1.0` passes sign-in & IOC against PR 3; deploy Hestia PR 4 only after upgrade to `2.0.0`.
- [ ] **Tag & Release:** `git tag -a v2.0.0 -m "Release 2.0.0"`.

### 10.3 Native Budget Reads — Default-Off / Post-`2.0.0` Gate (`Part C §11`)
Sits **outside the `2.0.0` release gate** behind a default-disabled client flag (`AppConfig.nativeBudgetEnabled == false` in `2.0.0`), with wire behavior frozen in `Part C §11`.
1. **Strict 4-part gate (UI presentation AND `APIClient` / `BearerAuthMiddleware` request dispatch):**
   - `AppConfig.nativeBudgetEnabled == true` (**`false` in `2.0.0`**), **AND**
   - `serverFeatures?.supports(.budgetNativeRead) == true` (`"budget_native_read"`), **AND**
   - `capabilities?.ownBudget?.canView == true && capabilities?.ownBudget?.permissions.contains(.budgetView) == true`, **AND**
   - Active exchanged `(origin, actor, owner_key)` device token whose **`issuedPermissions` contains `"budget.view"`** (`scope == "device"`).
2. **`budget.view`-only owner enrollment & recovery:** When `AppConfig.nativeBudgetEnabled == true` and `budget_native_read` is advertised, `ownBudget?.canView == true && permissions.contains(.budgetView)` qualifies for `POST /api/auth/device-token` even without receipt permissions (`Part C §11`), using the same §8.1 Decision Table & §8.2 journal for rotation/recovery.
3. **Transport & additive allowlist:** `BearerAuthMiddleware` adds the 6 frozen GET routes (`/api/budget/status`, `/api/budget/analytics/{monthly-budget, monthly-budget/charts, transactions, overview, categories}`, `0.46.0` bodies) additively to `receiptOperations` + self-revoke, verifying `issuedPermissions.contains("budget.view")` at dispatch and sending `Authorization: Bearer <device_token>` with zero `Cookie` (`400 budget_auth_ambiguous` if both).
4. **Teardown & Tests:** On `403`, `401`, feature loss, or switch, close native Budget views, zero cached ledger/analytics models, cancel in-flight requests, and discard late responses.
   - Zero-request tests (flag `false`): `BudgetGateTests.testZeroBudgetRequestsOn0460`, `testZeroBudgetRequestsOnPR2RollbackDespiteBrowserCanView`, `testZeroBudgetRequestsForReceiptOnlyDelegate`, `testRevocationOrSwitchTearsDownAndDiscardsLateResponse`.
   - Flag-on tests (`nativeBudgetEnabled == true`): `BudgetGateTests.testBudgetViewOnlyOwnerExchangesAndDispatchesOnlyWhenAllFourGatesPass` (tests missing server feature, missing `budget.view` grant, device token lacking `budget.view` in `issuedPermissions` at dispatch, and passing all 4 gates).

---

## 11. Later-PR Re-Review Gates (Non-Blocking Implementation Checks)

- **`V2b` / `V3`:** Verify `.legacyCodeRedeem` unverified identity across relaunch and same-origin account switch; verify REST `BoundSession` + SSE `SSESessionSnapshot` bindings under concurrent switches; verify QR HTTP-auth challenge rejection, redirect blocking, and that the post-confirm `GET /api/auth/features` probe on `target` runs strictly over the isolated transport against real `URLSession` (`URLProtocol`); enforce `actor == owner` restriction for legacy self-owner migration (`Part C §8`).
- **`V4`:** Verify both PR 3 → PR 2 rollback orderings (re-probing `features` before hitting `device_token_invalid`, and hitting `device_token_invalid` before foreground re-probe — freeing active slot for legacy owner pairing while keeping exchanged token in `rollbackQuarantine`); route manual `"Pair again"` through the §8.1 Decision Table; verify `DevicePairingAPI.revoke(_:server:)` always carries full old bearer + issuing origin.
- **`V5` / `V6`:** Verify real hestia `0.48.0` `GET /api/calendars/instances` fixtures, open-sheet discard (`AgendaView`), admin legacy receipt smoke across both `Legacy110ContractTests` (`v1.1.0`) and `LegacyReceipts090ContractTests` (`dd5df46`), and §10.3 native Budget gate tests (`nativeBudgetEnabled == true` and `false`).
- **`V2b` (migration faults):** Fault-inject every migration write boundary; persist the verified authoritative record before the `backend-legacy-migrated` marker; distinguish a locked Keychain read (`errSecInteractionNotAllowed`) from an absent item.
- **`V4` (in-flight exchange):** Test an account or origin switch while an exchange is in flight and recheck scope at response publication; for the slot-five browser recovery, verify device-identifying information survives restart and delegates are directed to the ledger owner.
