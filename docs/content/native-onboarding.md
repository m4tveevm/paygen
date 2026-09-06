# Configure a provider

The [dataset walkthrough](dataset-walkthrough.md) has complete examples for both
a successful setup and one that needs an operator's review. It also covers
adapter export and the difference between `demo` and `serve`.

Paygen imports OpenAPI 3.0 and 3.1 contracts without expanding every shared
reference. It expands only the operations you select. The profile supplies the
payment rules that the contract leaves open, such as direction, amount units,
settlement states and signing.

## Create and configure a project

Complete [toolchain setup](development.md#toolchain) and run in Bash from the
repository root. This copyable example uses the supplied native Paystack source
and reviewed profile; all output paths must be new. For your own API, replace
both fixture paths with your existing contract and profile files.

```bash
src/run cli init fixtures/native-paystack/openapi.yaml --output /tmp/new-provider
src/run cli configure /tmp/new-provider
src/run cli configure /tmp/new-provider --answers fixtures/native-paystack/profile.yml
src/run cli generate /tmp/new-provider
```

The configuration report lists operation candidates, source pointers, parameters
and unanswered questions. `--answers` applies a YAML/JSON profile;
`--set operations.create=OPERATION_ID` changes a single setting. For an existing
profile, pass `--profile FILE` to `init`.

Only inbound OpenAPI callback declarations are inferred as callback receivers.
An ordinary `/callbacks` path can be selected explicitly. Set an unwanted role
to `null` to suppress inference or recipe defaults. Partial profiles can be saved;
malformed structures are rejected. Generation requires all blocking questions
to be resolved.

## Saved decisions and changed contracts

`integration.yml` contains editable values; `review.json` records versioned,
per-field review evidence. It is an input to generation, owned by Paygen, and
contains fingerprints of explicit values and the relevant effective contracts.
Inferred operations and authentication stay `origin: inference` after `init` and
reload. A bundled recipe is an explicit reviewed configuration supplied by the
project, not a claim that the current developer has personally inspected it.
This review concerns **integration settings**, never approval or OTP for a payment.

The JSON report retains its existing fields. Each question also lists
`pending_decisions`; project provenance adds `review_state` and `review_required`.
States distinguish `inferred`, `confirmed`, `explicit-edit`, `explicit-override`,
`stale`, and `legacy`. Inspecting a project does not write review evidence.

Use `configure PROJECT --answers FILE` or `--set dotted.path=VALUE` to explicitly
confirm only the supplied fields, including an unchanged value. Manual YAML/JSON
profile edits also count as explicit choices while their relevant contract
basis is unchanged. A source or overlay change affecting a selected endpoint,
authentication scheme, or selected operation invalidates dependent decisions.
Unrelated endpoints, unused security schemes and the API title do not reset them.
For example, changing the create schema requires reviewing its mappings and
amount settings, while an unchanged callback signature decision is retained.

Apply overlays **before** confirming answers. After a contract/operation change,
manual edits cannot silently renew old evidence: review the reported paths and
reapply those fields through `configure`. Reading or regenerating does not
confirm anything. Generation stops on `REVIEW_STALE`; existing generated files
are retained but must not be treated as an updated service.

Projects created before `review.json` existed have unknown review history and
stop with `REVIEW_METADATA_REQUIRED`. Read their effective contract and existing
profile, correct any old guesses, then explicitly reapply the reviewed file:

```bash
src/run cli configure /tmp/new-provider --answers /tmp/new-provider/integration.yml
src/run cli generate /tmp/new-provider
```

Changing only a display name or confirming one field never approves the rest of
a legacy profile. Keep `review.json` alongside the source, overlays and profile
when moving a project; it contains local evidence, not an external authority or
a security boundary against a developer deliberately editing metadata.

## Examples from full specifications

| Example | Source size | Configured flow |
| --- | --- | --- |
| Paystack | 125 paths, 163 operations | Transfer to an existing recipient; `otp` maps to pending, with no OTP finalization |
| PayPal | 4 paths, 4 operations | Single-item payout batch; settlement follows the matching item |
| Raiffeisen | 20 paths with nested callbacks | Single-stage SBP payout without fiscalisation; exact ruble amounts and reconciliation |

```bash
src/run cli init fixtures/native-paystack/openapi.yaml \
  --profile fixtures/native-paystack/profile.yml --output /tmp/paystack-native
src/run cli generate /tmp/paystack-native
src/run cli init fixtures/native-paypal/openapi.json \
  --profile fixtures/native-paypal/profile.yml --output /tmp/paypal-native
src/run cli generate /tmp/paypal-native
src/run test src/spec/native_packs_spec.rb src/spec/russian_banks_spec.rb
```

These examples keep the source specifications unchanged and apply separate
profiles. Tests check generated adapters against independently defined HTTP
requests and responses. Paystack and PayPal exercise the HTTP transport through
WebMock; bank tests use an injected transport. All run offline. Each pack records
source, version, license and SHA-256. See
[Russian bank examples](ru-bank-examples.md) for bank-specific scope.

## Request parameters

Map path, query and header parameters separately. Legacy flat mappings apply to
path parameters only. Required values and schemas are checked before sending.

```yaml
parameter_mapping:
  status:
    path:
      id: provider_operation_id
    query:
      account_id:
        from: metadata.account_id
    header:
      Accept-Charset:
        value: UTF-8
```

The adapter supports primitive `simple` path/header parameters and `form` query
parameters, including primitive arrays. Cookies, objects, `deepObject`,
`allowReserved` and other unsupported serializations produce diagnostics.

`minor_units` emits an integer, `decimal_string` a decimal string, and
`decimal_number` an exact JSON number in major currency units. Application input
must be an integer or decimal string; floating-point money is rejected.

## Conditional request mappings

Use declarative rules when several payment methods share one API operation:

```yaml
request_mapping:
  recipient.type:
    from: payout_requisite.type
    default: sbp
  recipient.bank_code:
    from: payout_requisite.sbp.bank_code
    fallback_from: [payout_requisite.bank_code]
    when:
      from: payout_requisite.type
      equals: sbp
      default: sbp
```

The primary non-null value wins; `fallback_from` is ordered and `default` is used
only when all sources are null or absent. `false` and zero are values, not missing
data. `when` is a single equality test, not executable code. Inactive mappings
omit the target field. Request schema validation still runs after mapping. The
NovaPay profile uses these rules for separate SBP and card branches; an Overlay
states their conditional required fields without modifying the source snapshot.

`fallback_conflict: reject` refuses different non-null fallback values when the
primary field is missing. NovaPay uses this for phone selection: if both SBP and
card details contain different phones, supply the explicit common `phone` or
remove the irrelevant details. It never silently chooses a conflicting recipient.

## Response correlation

An API-valid response can still belong to another payment. Opt in with explicit
paths and roles; no mapping is guessed:

```yaml
response_bindings:
  merchant_reference:
    response_path: external_id
    operation_path: id
    roles: [create, status, cancel]
    required: true
  amount:
    response_path: amount
    operation_path: amount
    roles: [create, status, cancel]
    required: true
    response_unit: minor
```

The other supported keys are `currency` and `provider_id`. Amount bindings must
declare `response_unit: major` or `minor`; input units and scale come from the
amount profile. Comparison uses exact decimal arithmetic and rejects Float and
undeclared rounding. Missing required operation values are rejected before HTTP;
missing required response evidence or mismatches cannot update lifecycle state.
Optional evidence (`required: false`) may be absent or null, but a present value
must match. A mismatched create response is ambiguous and requires reconciliation.
NovaPay opts in for reference, amount and currency. Providers without these rules
do not gain a correlation guarantee. These rules apply to responses, not callbacks.

## Retry policy

The default is reconciliation before another create. Paygen sends an idempotency
header only when the profile names it. An empty policy, a header alone, or an
unconfirmed retention period cannot establish that repeating a payout is safe.

A confirmed create is cached by merchant operation identity. A lost response,
invalid successful response or other unresolved create requires status
reconciliation. Neither HTTP 404, an unknown status, a different caller-supplied
key nor expiry of a provider key permits another payout for the same operation.

For a documented provider guarantee, set `strategy: provider_key`, a `header` or
`body` key location, and positive integer `ttl_seconds`. Only an ambiguous retry
within that retention window may reach the provider again. Concurrent attempts
remain blocked and confirmed results stay cached beyond the retention window.
Choose the retention period from the provider contract. All included profiles
use conservative reconciliation when no retention period is configured.

Multiple workers and restart recovery require a shared durable state store and
a stable merchant `state_namespace` or `account`. Keep the scope unchanged during
key rotation; see [state and migration rules](architecture.md).

## Import corpus

`fixtures/corpus/` records a snapshot of **21 API brands**, selected for varied
formats and payment flows. Its pinned report records **13 successful full-contract
imports**: PayPal, Adyen, Modern Treasury, Lithic, Paystack, Plaid, Yapily, ZBD,
Circle, TransferZero,
Nomupay, Raiffeisen and T-Bank. Import success is separate from having an
executable payment profile.

| Source | Recorded import result |
| --- | --- |
| Stripe | Parsed node budget exceeded |
| Dwolla, Mollie, Razorpay | OpenAPI validation errors |
| Square | Missing reference target |
| Currencycloud, Griffin | Swagger 2.0 requires conversion |
| Rapyd | Non-finite numeric scalar rejected |

The manifest pins URLs, byte counts and SHA-256 hashes. Download the exact files
to a cache, then rerun the check offline:

```bash
src/run exec ruby script/corpus /path/to/source-cache > corpus-result.json
```

Changed or missing files are reported separately. The sample also includes
semantic counterexamples: recursive payment-order schemas in Modern Treasury,
TransferZero's sandbox fake-payout action, Square's reconciliation API and
T-Bank's certificate signing and confirmation requirements.

## Export documentation and test requests

`generate` emits `INTEGRATION.md`, `fixtures.json`, the effective OpenAPI document
and provenance alongside the service. Export a portable copy with:

```bash
src/run cli docs /tmp/new-provider --format html --output /tmp/provider-docs
src/run cli collection /tmp/new-provider --format bruno --output /tmp/provider-bruno
```

Use `--format md` for Markdown documentation. Export destinations must be new and
outside the project. HTML export requires no Node installation and can be viewed
locally, archived or hosted. GitHub Pages publishes the Paygen manual independently
of these per-integration files. See [the Bruno demo](bruno-demo.md) to run the
exported requests.
