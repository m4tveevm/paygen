# Offline provider packs

Each pack combines a pinned contract, a standards-shaped correction overlay,
an explicit semantic profile, synthetic responses and signed test webhooks.
`provenance.json` records source ownership, version, reference commit, license
and SHA-256 digests. All credentials in `fixtures.json` are public test strings.

| Pack | Boundary | Important behavior |
| --- | --- | --- |
| NovaPay | Supplied fictional SBP API | The original is unchanged; the overlay restricts recipients to SBP and requires the bank code. |
| PayPal | One email recipient per Standard Payouts batch | Batch success only means processing completed. Resolve the matching sender item before approving. |
| Stripe | Standard bank payout from an existing Connect account | `paid` may subsequently become `failed`; account and mode must match. |
| Adyen | Transfers v4, outgoing bank transfer to an existing transfer instrument | `booked` remains pending settlement and may become `returned`. |

The three real-provider contracts are deliberately restricted, authored
representations. Their local `/webhooks/*` paths describe the integration's
receiver, not a provider-hosted API endpoint. EUR/USD restrictions are choices
of these packs, not claims about each provider's full currency support.

`fixtures.json` contains a decimal-string operation, test credentials, fixed
clock, named HTTP responses, and webhook payload/raw bytes/header triples.
`scenarios.yml` refers to those names and records the expected canonical states.
The test suite builds the adapters through public project and generator APIs,
uses an injected transport, and checks the exact request representation and
callback behavior. No provider account or network access is required.

The PayPal signature boundary requires an application-supplied verification
hook. The default rejects callbacks. Tests substitute that boundary explicitly;
they do not claim that synthetic messages have valid PayPal signatures.

The Adyen subset deliberately has no `approved` mapping. Booking alone cannot
prove delivery. Applications that need final settlement confirmation must add
and validate a reconciliation policy for the relevant bank rail and tracking
events before extending this profile.
