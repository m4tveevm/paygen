# Full native APIs and explicit integration decisions

Paygen retains the full source reference graph and expands selected operation
contracts. This avoids duplicating every component into every operation. Input
budgets remain 10 MiB, 100,000 nodes, 100 nesting levels, 1,000 expanded references
and 32 files. Unsupported recursion in a selected schema produces a diagnostic.
Legal recursion in unrelated schemas does not prevent import.

## Configure an unfamiliar provider

```bash
bundle exec bin/paygen init provider.yaml --output /tmp/new-provider
bundle exec bin/paygen configure /tmp/new-provider
bundle exec bin/paygen configure /tmp/new-provider --answers confirmed-profile.yml
bundle exec bin/paygen generate /tmp/new-provider
```

The configuration report lists candidate operations and their evidence, selected
parameters, source provenance and questions requiring a documented answer.
Method names suggest candidates; they do not establish money direction,
settlement, units or signing rules. Only OpenAPI inbound callback declarations
are inferred as receivers. Plain `/callbacks` paths can be selected explicitly.
Set an unwanted role to `null` to suppress inference or recipe defaults.

Profiles are YAML/JSON data. `--set operations.create=OPERATION_ID` is useful for
small edits. `init --profile FILE` applies an already reviewed profile directly.
Unknown statuses never approve a transfer. Partial profiles are editable;
malformed configuration structures are rejected before they are saved.

## Native examples with independent HTTP expectations

| Example | Full source | Reviewed flow |
| --- | --- | --- |
| Paystack | 125 paths, 163 operations | Initiate and fetch a transfer to an existing recipient; OTP stays pending |
| PayPal | 4 paths, 4 operations | Single-item payout batch; inspect the matching item, never approve from batch success alone |
| Raiffeisen | 20 paths, including nested callbacks | Single-stage SBP payout without fiscalisation; exact ruble numbers and reconciliation before retry |

```bash
bundle exec bin/paygen init fixtures/native-paystack/openapi.yaml \
  --profile fixtures/native-paystack/profile.yml --output /tmp/paystack-native
bundle exec bin/paygen generate /tmp/paystack-native
bundle exec bin/paygen init fixtures/native-paypal/openapi.json \
  --profile fixtures/native-paypal/profile.yml --output /tmp/paypal-native
bundle exec bin/paygen generate /tmp/paypal-native
bundle exec rspec spec/native_packs_spec.rb spec/russian_banks_spec.rb
```

These tests use independently authored HTTP expectations and documented
responses. They exercise the generated adapter, including its real HTTP transport
through WebMock for Paystack/PayPal. No source rewrite or contract overlay makes
these examples pass. Licenses, source versions, SHA-256 and scope are stored
beside each pack. See [Russian bank examples](ru-bank-examples.md) for the
Raiffeisen flow and the T-Bank/Tochka counterexamples.

## Request parameters and retry policy

Declare query/header mappings by location; legacy flat mappings apply to path
parameters only. Required values and schemas are checked before HTTP. Primitive
`simple` path/header values and `form` query values are supported, including
primitive arrays. Cookies, objects, `deepObject`, `allowReserved` and unsupported
serializations produce diagnostics.

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

`decimal_number` emits an exact JSON number in major currency units, while
`minor_units` emits integer minor units and `decimal_string` emits a decimal
string. Application input remains an integer or decimal string; Float money is
rejected.

Use `idempotency.strategy: reconcile_before_retry` when the provider's duplicate
submission guarantee has not been established. With `header: null`, Paygen omits
an undocumented idempotency header. A confirmed create is cached; an ambiguous
attempt requires status reconciliation. Neither 404 nor an unknown status
authorises another payout. Production recovery and coordination between workers
require an injected durable state store.

## Corpus results and counterexamples

The recorded benchmark contains **21 distinct API brands** selected for varied
formats and payment flows. This is a deliberate diversity sample. It is not a
statistically random sample or 21 working adapters.

At the recorded snapshot, **13 of 21 full native contracts pass import**:
PayPal, Adyen, Modern Treasury, Lithic, Paystack, Plaid, Yapily, ZBD, Circle,
TransferZero, Nomupay, Raiffeisen and T-Bank. Explicit semantic profiles are still
needed before code generation. The remaining import outcomes are:

| Source | Recorded boundary |
| --- | --- |
| Stripe | Parsed node budget exceeded |
| Dwolla, Mollie, Razorpay | OpenAPI validation errors retained in the report |
| Square | A missing reference target |
| Currencycloud, Griffin | Swagger 2.0 requires a separate explicit conversion |
| Rapyd | A non-finite numeric scalar is rejected |

The machine-readable manifest and report live in `fixtures/corpus/`. Each source
has a URL, byte count and SHA-256. After downloading those exact files into a
cache, rerun without network access:

```bash
bundle exec ruby script/corpus /path/to/source-cache > corpus-result.json
```

A changed or missing source is reported separately. The report measures import
and semantic inspection. Adapter replay remains a separate test tier.

Useful counterexamples include Modern Treasury's selected recursive payment
order schemas, TransferZero's sandbox-only fake-payout action, Square's payout
reconciliation surface, and T-Bank's signature and confirmation requirements.
The two invalid Dwolla Header Reference Objects remain visible after fixing
relative OAuth URLs; accepting a relative token URL does not make the rest of an
invalid source valid.

## Portable documentation and testing

`generate` always emits Markdown, fixtures, effective OpenAPI and provenance.
`docs --format html` creates a local browsable copy of the same integration,
without Node. It can be archived or hosted by the receiving team. Publishing the
Paygen manual on GitHub Pages is optional and independent of this output.
See [Bruno adapter demo](bruno-demo.md) for a runnable HTTP collection.
