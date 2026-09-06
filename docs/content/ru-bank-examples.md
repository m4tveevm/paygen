# Russian bank examples

You can run the Raiffeisen scenario locally. The T-Bank and Tochka examples are
reviews of APIs that still need integration work; they are not working adapters.

| Bank and product | Materials | Scope |
| --- | --- | --- |
| Raiffeisen SBP payouts | Full OpenAPI 3.0.3, profile, synthetic requests and responses | Create, status, rejection, exact ruble amounts and reconciliation before retry |
| T-Bank bulk A2C/E2C payouts 1.46 | Full OpenAPI 3.0.2 and requirements review | Certificate signatures, Init → Payment, POST status requests |
| Tochka payment orders | Official documentation review | Order signing, execution polling and final status |

The Raiffeisen and T-Bank specifications came from
`__redoc_state.spec.data` on the official pages. The snapshots keep every path,
schema and example. Each `provenance.json` records the source, retrieval date and
SHA-256 of both the page and specification. The profiles and synthetic fixtures
remain separate from those original contracts.

Run commands from the checkout root after [Ruby setup](development.md#toolchain).
Output directories must be new.

## Raiffeisen: local SBP payout scenario

The profile selects `POST /v2/payouts` and `GET /payout/v2/payouts/{id}` for a
single-stage payout to an individual without fiscalisation (`fiscal=false`).
Authentication uses `Authorization: Bearer secretKey`. The application supplies
the debit account, payment purpose, phone and SBP participant identifier
`payoutParams.bankId`; this identifier is distinct from the bank's BIC.
See the [official contract](https://pay.raif.ru/doc/payout.html).

The amount `"1110.01"` becomes the exact JSON number `1110.01` in rubles.
`COMPLETED` maps to `approved`, `DECLINED` to `rejected`, and intermediate states,
including `WAITING_CONFIRMATION`, `DRAFT` and `ON_SIGNING`, to `in_progress`.

```bash
src/run cli init fixtures/raiffeisen_payouts/upstream/openapi.json \
  --output /tmp/paygen-raiffeisen-demo
src/run cli generate /tmp/paygen-raiffeisen-demo
src/run test src/spec/russian_banks_spec.rb
```

Tests call the generated adapter through an injected transport and compare HTTP
requests with independently defined expectations. Export a [Bruno collection](bruno-demo.md)
for interactive checks.

The unique `id` supports reconciliation. `reconcile_before_retry` retains confirmed
results and requires a status lookup using the original `id` after an ambiguous
response. HTTP 404 and failed reconciliation do not permit a second payout.
No `Idempotency-Key` header is added. Multiple processes and restart recovery need
a shared durable state store.

Webhooks require a separate implementation: the bank signs
`amount|id|statusValue|statusDate`, whereas Paygen's generic HMAC mode uses raw JSON
bytes. The profile also excludes two-stage requests, batches and fiscalisation.
Some optional upstream examples contain numbers where the schema declares strings
(`inn`, `currencyOperationCode`, `agreementNumber`). The snapshot preserves this
discrepancy; the executable example does not use those fields.

## T-Bank: signing and confirmation

`Init` declares `security: []`, but its body requires `DigestValue`,
`SignatureValue` and `X509SerialNumber`. The documentation describes RSA and GOST.
The `Token` signature used by certain auxiliary methods does not replace payout
signing. See the [version 1.46 documentation](https://www.tbank.ru/business/online-payments/dev/payouts/).

`Init` returns an identifier and `CHECKED` status, followed by `Payment`.
`Success=true` indicates a successful request; payout completion is determined
separately. `GetState` uses POST and a signed body. `Amount=1751` represents
17.51 rubles. This product does not support cancelling a card payout.

```bash
src/run cli inspect fixtures/tbank_payouts/upstream/openapi.json --format json
```

`review.yml` records requirements for further implementation. Tests reject an
unsigned example and block generation until required semantic settings are
configured. The repository has no executable T-Bank adapter.

## Tochka: creating an order and executing it

`WaitingForCreate` means that signing in online banking is pending. `Created`
also does not confirm execution; the final successful status is `Paid`. The flow
requires signing and subsequent polling. See [payment orders](https://developers.tochka.com/docs/tochka-api/opisanie-metodov/platezhi).

The acquiring operation `Create Payment Operation` creates an incoming-payment
link. It must not be selected as an outgoing payout. See [payment links](https://developers.tochka.com/docs/tochka-api/opisanie-metodov/platyozhnye-ssylki/bez-fiskalizacii).

At the snapshot date, 5 September 2026, the full specification endpoint returned
HTTP 502. The repository retains an official-documentation review with status
`source_unavailable`; it has neither a full OpenAPI snapshot nor an executable
adapter for Tochka.

## Verification scope

Examples use synthetic recipient data and local transports. The Raiffeisen
scenario is checked against its pinned contract. Bank sandbox acceptance, product
activation and actual payment execution require separate work. T-Bank and Tochka
illustrate requirements that must be resolved before creating executable profiles.
