# V6 imported receipt review

## Scope and default

V6 adds a DEBUG-only phone flow for receipts already imported by hestia. It lists `status: imported` receipts with the default `evidence: exclude`, pages through the result, and groups rows by merchant. A detail view offers bank candidates, an explicit no-link choice, and single confirmation. Each merchant group also has a bulk action that always confirms with `link: null`.

The existing scan → parse → confirm flow is unchanged. Gmail import controls, receipt images, search, and editing imported receipt fields are out of scope.

V6 is **default-off**. `AppConfig.receiptReviewEnabled` remains `false`, and Release always returns `false`. For DEBUG UAT, add `-vesta.receiptReview` to the scheme's launch arguments. The entry point is on Home.

## Gates and transport

Presentation, exchange eligibility, and every review request require:

1. The DEBUG build flag.
2. Current capabilities containing `budget.receipts.view` and `budget.receipts.edit` in an eligible own/delegated receipt scope.
3. A current exchanged V4 device token bound to the session actor and origin, with a non-empty owner/owner key, a known device scope, and `issued_permissions` containing view/edit.

Choosing a candidate additionally requires both current capabilities and issued token permissions to contain `budget.receipts.match`. Without match, candidates and selection are cleared and only `link: null` can be sent. A linked confirmation is refused locally if match is absent.

List, detail, and review-confirm requests clear `Cookie` and the session bearer. They send only `Authorization: Bearer <device_token>`; there is no cookie or session fallback. The receipt allowlist now uses the generated list/detail operation IDs. Review confirmation uses a review-scoped client so its device-token permission check differs from the existing add-receipt scan path without changing that path.

A 401, 403, flag change, capability/token withdrawal, account switch, origin switch, or sign-out clears cached receipt/detail data and terminates the store. Session-bound APIs revalidate after every awaited operation, so late responses and late denials cannot republish into a newer session. V4 rotation and its journal remain unchanged.

## Review rules

- The list request sends `status: imported`, `evidence: exclude`, and `limit: 200`, then follows distinct cursors.
- Merchant groups use a non-empty `chain_key` when available, otherwise normalized case-insensitive shop names; missing names share an Unknown merchant group.
- Exactly one candidate with `match_strength` `nip` or `distinctive` is preselected. Zero candidates, multiple candidates, or weaker strengths leave nothing selected.
- A single confirm uses the chosen signed candidate link or explicit `link: null`.
- Bulk confirm fetches each receipt's current detail and then confirms it before moving to the next. Every confirm uses that detail's own `version` as `expected_version` and always sends `link: null`.
- Non-auth failures do not stop the rest of a merchant batch. Outcomes remain visible per receipt with codes such as `budget_receipt_conflict` and `already_submitted`. Confirmed and already-submitted rows leave the pending list; failed rows remain.
- `gateway_status`, `payee_host`, and `has_document` remain optional. They are rendered only when supplied; a false `has_document` plus `payee_host` produces the download hint. No default `has_document: true` is inferred for display.

## OpenAPI pin

`Vesta/openapi.json` remains a hand-pinned subset with `info.version: 0.9.0`. Do not run `make pull-spec`.

V6 appends these operations verbatim from hestia **0.55.0, commit `1b269c8`**:

- `POST /api/budget/receipts/list`
- `GET /api/budget/receipts/detail`

It also appends the verbatim `BudgetReceiptListRequest`, `BudgetReceiptListResult`, `BudgetReceiptSummary`, `BudgetReceiptDetailResult`, and `BudgetReceiptPaymentEvidence` schemas. The shared `BudgetReceiptCandidate`, `BudgetReceiptDetail`, and `BudgetReceiptLine` schemas are replaced with their deployed `1b269c8` versions. This adds required candidate strength/dates, imported status and email/attachment source values, optional imported-payment metadata, and strict required-null line fields. Existing draft/confirmed/needs-review and live_text/local_ocr/cloud_ai values remain valid.

The pinned confirm operation, `BudgetReceiptConfirmRequest`, `BudgetReceiptConfirmResult`, `BudgetReceiptLinkRequest`, and `BudgetReceiptLineInput` are unchanged. The existing confirm pin already has `receipt_id`, `expected_version`, and nullable link behavior through `ExplicitNullsMiddleware`; no confirm diff is needed.

The generator drops required nullable `anyOf` properties. Wire overrides therefore decode required nullable keys with `decode(Optional.self)`, which rejects an absent key but accepts explicit null, while optional Gmail hint keys use `decodeIfPresent` and may be absent. The parse fixture now carries the deployed required `match_strength`; both legacy contract targets retain their own unchanged specs.

## UAT checklist

- [ ] Without `-vesta.receiptReview`, verify Home has no imported-review entry and zero list/detail/review-confirm requests.
- [ ] In DEBUG with the flag, use an exchanged token with view/edit. Verify imported rows group by merchant and all list pages load.
- [ ] With exactly one `nip` candidate and then one `distinctive` candidate, verify it is preselected. Verify zero, two, `generic`, and `none` candidates produce no selection.
- [ ] Confirm one receipt with a chosen candidate; confirm another with “Don’t link”. Inspect the server ledger and links.
- [ ] Remove match from either capabilities or the issued token. Verify candidates disappear and only no-link confirmation is possible.
- [ ] Bulk-confirm a merchant. Verify requests are sequential, every receipt uses its own current version, and no bank link is applied.
- [ ] Mix success, `budget_receipt_conflict`, and `already_submitted` in one batch. Verify all items are attempted, each outcome is shown, and only failures remain pending.
- [ ] Verify present `gateway_status`/`payee_host`/`has_document` hints, including the no-document download hint, and their absence on older payloads.
- [ ] Return 401 and 403, revoke/rotate the token, and switch account/origin during a held response. Verify the sheet clears and late data does not return.
- [ ] Exercise V1 scan/parse/confirm and V4 rotation/recovery; verify the journal is unchanged and the existing flow still works.
- [ ] Build Release and verify the launch argument cannot enable V6.

## Open questions / hestia gaps

- Imported receipts still need the fields required by the existing confirm contract (valid date, total, currency, and internally consistent lines). V6 reports `incomplete_receipt` instead of sending a request that hestia would reject; a dedicated imported-receipt edit flow is not included.
- Hestia has no bulk endpoint, so the phone intentionally performs detail/confirm pairs sequentially. An access denial tears down the session and prevents further sends rather than continuing under invalid authorization.
- Search and image operations are not needed for this fast review flow and remain unpinned.
