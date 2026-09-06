# Paystack: full native specification

`openapi.yaml` is an unchanged, complete official snapshot. `profile.yml` selects
two operations and supplies business meanings separately. There is no source
overlay, reduced replacement specification, provider recipe, or provider branch
inside Paygen's runtime.

```sh
src/run cli init fixtures/native-paystack/openapi.yaml \
  --profile fixtures/native-paystack/profile.yml --output /tmp/paystack-native
src/run cli generate /tmp/paystack-native
src/run test src/spec/native_packs_spec.rb
```

The profile covers one NGN transfer to an **already registered recipient code**,
followed by transfer lookup. Amount input is a decimal string in naira; the wire
amount is an integer in kobo. Supply `secret_key` through runtime credentials.
Keep the original `operation.id` as the body `reference` on retries. Paystack
documents a 16–50 character reference containing lowercase letters, digits,
underscores and dashes. The snapshot mistakenly uses numeric `minimum` on this
string and therefore does not enforce those reference constraints; validate them
in the owning application's input boundary. `oracle.json` uses a valid reference.

The HTTP envelope's boolean `status` reports request handling. The transfer state
comes from `data.status`; the stable lookup identity is `data.transfer_code`, not
the numeric `data.id`. `pending`, `received`, and `otp` stay `in_progress`.
`success` means provider processing completed, which does not promise instant
credit to the recipient. A reversal is preserved as `reversed`.

The authored offline oracle asserts literal URLs, Bearer authorization, the exact
request body, stable retry reference, status lookup identity, failure/OTP handling,
and rejection of unknown status. It validates its request and response bodies
against the untouched native schemas. It does not derive expected values from
Paygen mappings or its simulator. The tests use the generated service and real
HTTP transport with network calls intercepted by WebMock.

Recipient registration, OTP finalization, merchant approval callbacks, webhook
verification, account enablement, and live settlement are outside this profile.
It is an offline contract example, not a claim of production certification.

Sources: [transfer API](https://paystack.com/docs/api/transfer/),
[transfer lifecycle](https://paystack.com/docs/transfers/how-transfers-work/),
[retry reference](https://paystack.com/docs/transfers/single-transfers/).
See `provenance.json` for the pinned source commit, checksums and MIT license.
