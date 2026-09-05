# Configure a provider

Paygen imports OpenAPI 3.0/3.1 and retains shared references, expanding only
selected operations. A profile defines payment semantics that the specification
does not establish: direction, amount units, settlement states and signing rules.

## Create and configure a project

```bash
bundle exec bin/paygen init provider.yaml --output /tmp/new-provider
bundle exec bin/paygen configure /tmp/new-provider
bundle exec bin/paygen configure /tmp/new-provider --answers confirmed-profile.yml
bundle exec bin/paygen generate /tmp/new-provider
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

## Examples from full specifications

| Example | Source size | Configured flow |
| --- | --- | --- |
| Paystack | 125 paths, 163 operations | Transfer to an existing recipient; OTP remains pending |
| PayPal | 4 paths, 4 operations | Single-item payout batch; settlement follows the matching item |
| Raiffeisen | 20 paths with nested callbacks | Single-stage SBP payout without fiscalisation; exact ruble amounts and reconciliation |

```bash
bundle exec bin/paygen init fixtures/native-paystack/openapi.yaml \
  --profile fixtures/native-paystack/profile.yml --output /tmp/paystack-native
bundle exec bin/paygen generate /tmp/paystack-native
bundle exec bin/paygen init fixtures/native-paypal/openapi.json \
  --profile fixtures/native-paypal/profile.yml --output /tmp/paypal-native
bundle exec bin/paygen generate /tmp/paypal-native
bundle exec rspec spec/native_packs_spec.rb spec/russian_banks_spec.rb
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

Multiple workers and restart recovery require a shared durable state store.

## Import corpus

`fixtures/corpus/` records a snapshot of **21 API brands**, selected for varied
formats and payment flows. **13 full contracts pass import**: PayPal, Adyen,
Modern Treasury, Lithic, Paystack, Plaid, Yapily, ZBD, Circle, TransferZero,
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
bundle exec ruby script/corpus /path/to/source-cache > corpus-result.json
```

Changed or missing files are reported separately. The sample also includes
semantic counterexamples: recursive payment-order schemas in Modern Treasury,
TransferZero's sandbox fake-payout action, Square's reconciliation API and
T-Bank's certificate signing and confirmation requirements.

## Export documentation and test requests

`generate` emits `INTEGRATION.md`, `fixtures.json`, the effective OpenAPI document
and provenance alongside the service. Export a portable copy with:

```bash
bundle exec bin/paygen docs /tmp/new-provider --format html --output /tmp/provider-docs
bundle exec bin/paygen collection /tmp/new-provider --format bruno --output /tmp/provider-bruno
```

Use `--format md` for Markdown documentation. Export destinations must be new and
outside the project. HTML export requires no Node installation and can be viewed
locally, archived or hosted. GitHub Pages publishes the Paygen manual independently
of these per-integration files. See [the Bruno demo](bruno-demo.md) to run the
exported requests.
