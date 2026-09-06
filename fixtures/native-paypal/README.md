# PayPal Payouts: full native specification

`openapi.json` is the complete, unchanged official Payouts v1 specification.
`profile.yml` selects one-recipient batch creation and batch lookup. This is
separate from the existing curated PayPal pack: no replacement schema, source
overlay or prepared recipe is applied to the native document.

```sh
src/run cli init fixtures/native-paypal/openapi.json \
  --profile fixtures/native-paypal/profile.yml --output /tmp/paypal-native
src/run cli generate /tmp/paypal-native
src/run test src/spec/native_packs_spec.rb
```

The profile covers one email recipient and USD. The application supplies an
OAuth access token with the payouts scope; token acquisition stays with the
application's token provider. The chosen default server is PayPal Sandbox.
An amount such as `"123.45"` remains an exact decimal string on the wire.

Keep the original operation ID in `sender_batch_header.sender_batch_id` and
`items[0].sender_item_id`. Paygen additionally sends a stable `PayPal-Request-Id`.
PayPal documents duplicate protection for the same sender batch ID within
30 days. Do not reuse an old identifier as a new payment outside that window.

Batch `SUCCESS` means the batch was processed; individual items may still fail
or remain unclaimed. This profile approves only a matching item's `SUCCESS`.
The independent oracle deliberately returns batch `SUCCESS` with item `FAILED`,
which must become `rejected`. Missing or ambiguous matching-item evidence must
stop approval. The request/response oracle is authored separately from Paygen's
mapping and simulator and checked against the full native schemas.

The tests execute the generated service and actual HTTP transport with requests
intercepted by WebMock. They do not contact PayPal. Multi-recipient orchestration,
pagination of large batches, cancellation, webhook verification, access-token
acquisition and live settlement are outside the profile's demonstrated scope.

Sources: [create payouts](https://developer.paypal.com/api/payments.payouts-batch/v1/payouts-post),
[batch lookup](https://developer.paypal.com/api/payments.payouts-batch/v1/payouts-get),
[batch status and duplicate protection](https://developer.paypal.com/api/payments.payouts-batch/v1/definitions/payout_batch_header).
See `provenance.json` for the pinned source commit, hashes and Apache-2.0 license.
