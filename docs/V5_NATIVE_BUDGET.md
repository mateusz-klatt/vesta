# V5 native Budget reads

## Scope and default

V5 adds read-only native Budget analytics to the existing Budget sheet: monthly budget and transactions, overview totals, the category catalog, and six-month chart bars. It adds no writes and no receipt behavior changes.

Native Budget is **default-off**. `AppConfig.nativeBudgetEnabled` remains `false`; production and Release builds cannot enable it. For DEBUG UAT only, add `-vesta.nativeBudget` to the scheme's launch arguments before starting the app.

## Four-part gate

Presentation and every request require all of the following:

1. The build flag is enabled (production `false`, or the DEBUG UAT override).
2. `/api/auth/features` advertises `budget_native_read`.
3. Capabilities contain `ownBudget.canView == true` and `ownBudget.permissions` containing `budget.view`.
4. The current `(origin, actor, owner_key)` has an exchanged token with `scope == "device"` and `issuedPermissions` containing `budget.view`.

An owner with only `budget.view` is eligible for the normal V4 device exchange when gates 1–2 hold and gate 3 is present; receipt permissions are not required. A token carrying `budget.view` must have `device` scope. Rotation, recovery, and the journal remain the V4 paths. A native-read 401/403 tears down Budget but does not revoke the token.

Transport accepts only the six frozen GET routes. It rechecks `issuedPermissions` at dispatch, clears both `Cookie` and session `Authorization`, and sends only `Authorization: Bearer <device_token>`. The existing origin and `/api/budget` redirect guards are unchanged. Requests are refused locally when any gate fails.

A 401, 403, feature loss, account switch, origin switch, or flag change closes Budget, clears all cached models, cancels store work, and invalidates every outstanding session-bound read so late responses are discarded.

## OpenAPI pin

The hand-pinned `Vesta/openapi.json` remains `info.version: 0.9.0`; do not run `make pull-spec`. V5 appends these operations verbatim from hestia **0.55.0, commit `57a3395`**, together with their 17 missing transitive schemas:

- `GET /api/budget/analytics/monthly-budget/charts`
- `GET /api/budget/analytics/overview`
- `GET /api/budget/analytics/categories`

The other native-read routes are `GET /api/budget/status`, `/api/budget/analytics/monthly-budget`, and `/api/budget/analytics/transactions`.

The three pre-existing native-read path objects are not verbatim 0.55.0: each now has `x-required-permission: budget.view`, and monthly-budget has a newer description. After applying the repository's nullability normalization, the pre-existing schemas match 0.55.0 except that 0.55.0 adds `card_debt` to `BudgetAnalyticsMonthlyBudget`. V5 deliberately leaves all pre-existing entries unchanged.

The generator drops required nullable `anyOf` fields. Type overrides preserve the verbatim schema's chart series and category metadata without normalizing the new JSON.

## UAT checklist

- [ ] Without `-vesta.nativeBudget`, an advertising server still shows no Budget entry point and sends zero native Budget requests.
- [ ] In a DEBUG build with `-vesta.nativeBudget`, sign in as an owner with `ownBudget.canView`, `budget.view`, and no receipt permissions.
- [ ] Confirm one V4 device exchange returns `scope: device` and `issued_permissions` containing `budget.view`; no receipt permission is granted.
- [ ] Open Budget and verify monthly data, transactions, overview totals, category names/colors, and chart bars. Pull to refresh and change month/currency.
- [ ] Remove `budget_native_read` or the `budget.view` grant: the sheet closes and cached data clears. A late response must not repopulate it.
- [ ] Return 401 and 403 on native reads: the sheet closes, late responses are discarded, and no device-token revocation is sent.
- [ ] Switch account and then origin while a read is in flight: data clears and the late response is discarded.
- [ ] Confirm receipt pairing, rotation, interrupted-journal recovery, and receipt submission still work; 401/403 on the exchange must not revoke the prior token.
- [ ] Build Release without the DEBUG argument and confirm native Budget remains unavailable.
