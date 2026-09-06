# Provider examples

The packs contain pinned contracts, declarative profiles and synthetic test data.
`provenance.json` records source ownership, version, license and SHA-256 hashes.
Credentials in `fixtures.json` are public test strings. Tests run without provider
accounts or live payments.

## Focused contracts

| Pack | Scope | Status behavior |
| --- | --- | --- |
| `novapay` | Supplied fictional SBP API; overlay requires SBP bank code | Completed payout becomes approved |
| `paypal` | One email recipient per Standard Payouts batch | Resolve the matching item before approval |
| `stripe` | Bank payout from an existing Connect account | `paid` can later become `failed`; account and mode must match |
| `adyen` | Transfers v4 to an existing bank transfer instrument | `booked` stays pending and can become `returned` |

PayPal, Stripe and Adyen use authored subsets of their official contracts.
Local `/webhooks/*` paths describe the application's receiver. Currency
restrictions belong to these profiles. Each pack includes an overlay, a profile,
`fixtures.json`, `scenarios.yml` and an Arazzo create/status workflow.

Fixtures contain an operation with a decimal-string amount, fixed clock, named
HTTP responses, and webhook payload/raw-body/header triples. Tests generate the
service through public project APIs and check request representation, mapped
results and callback handling against an injected transport.

PayPal callbacks require an application-supplied verification hook, which rejects
by default. The Adyen profile has no `approved` mapping: final settlement requires
a separate reconciliation policy for the relevant rail and tracking events.

## Full native contracts and reviews

| Directory | Scope |
| --- | --- |
| `native-paystack` | Full 125-path OpenAPI, transfer profile and independent HTTP expectations |
| `native-paypal` | Full payouts API, single-item profile and independent batch/item checks |
| `raiffeisen_payouts` | Full OpenAPI, SBP profile, exact ruble amounts and reconciliation tests |
| `tbank_payouts` | Full OpenAPI and certificate-signing/two-stage requirements; no executable profile |
| `tochka_payment_review` | Official-documentation review; native specification unavailable |
| `corpus` | Manifest and import results for 21 API brands, with 13 successful imports |

Native examples keep the specifications unchanged and define payment behavior in
separate profiles. Their HTTP expectations are independent of the simulator.
`review.yml` documents unsupported scenarios; it is not an integration profile.
An import result establishes structural compatibility, separate from adapter
execution. See [provider configuration](../docs/content/native-onboarding.md) and
[Russian bank examples](../docs/content/ru-bank-examples.md).

## Replay an Arazzo workflow

Supply the effective OpenAPI document under the `provider` source name and the
native request body from `fixtures.json`. The workflow transport owns HTTP
authentication; the generated adapter owns application-to-provider amount
conversion. A successful workflow result means its HTTP checks passed: inspect
the returned payout state before interpreting settlement. See
[the workflow interface](../docs/content/architecture.md#overlay-and-arazzo-support).
