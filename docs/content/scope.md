# Scope and verification

Paygen generates a Ruby payout integration from an OpenAPI document and a payment
profile. It parses the contract, generates the service and its documentation, and
verifies the result locally. The NovaPay example has separate SBP and card
recipient mappings with conditional schema validation. The other profiles cover
different API shapes and payment rules.

## Case requirements

| Requirement | Implementation | Verification |
| --- | --- | --- |
| Parse methods, parameters, requests, responses and authentication | OpenAPI 3.0/3.1 graph import and operation inventory | `input_spec.rb`, `input_graph_spec.rb`, `ir_spec.rb` |
| Recognize payment states, errors and callbacks | Explicit status/error mappings, callback declarations and ambiguity diagnostics | `ir_spec.rb`, `onboarding_spec.rb`, `runtime_adapter_spec.rb` |
| Generate a `Provider::BaseService` integration | Generated subclass with `check_conditions`, `create_request`, `fetch_status` and `process_callback` | `project_spec.rb`, `packs_spec.rb`, backend compatibility harness |
| Build and send requests; configure endpoints and credentials | Injectable HTTP transport, authentication and per-role mappings | `runtime_adapter_spec.rb`, `native_packs_spec.rb` |
| Convert amounts and validate fields | Exact decimal/integer transforms, required fields and schema validation | `runtime_adapter_spec.rb`, `russian_banks_spec.rb` |
| Process incoming notifications | Raw-body signature verification, event/status validation and replay handling | `runtime_security_spec.rb`, `runtime_demo_spec.rb` |
| Produce `INTEGRATION.md` and `fixtures.json` | Configuration, methods, statuses, errors, named requests/responses and callbacks | `generated_docs_spec.rb` |
| Provide a repeatable CLI workflow | `init`, `configure`, `generate`, `docs`, `collection`, `demo`, `verify` | `cli_spec.rb`, `collection_spec.rb`, CLI smoke checks |
| Check payment sequences | Bounded seeded state fuzzing, shrinking and replay | Independent faulty-adapter regressions; NovaPay/Raiffeisen CI sequences |
| Adapt to different providers and expose unsupported features | Declarative recipes/profiles, overlays, extension hooks and diagnostic codes | Seven executable profiles, native-contract tests and the import corpus |
| Use Ruby and open-source components | Ruby parser, generator and runtime; dependency locks and MIT project license | `src/paygen.gemspec`, `LICENSE`, dependency audits |

Spec filenames above are relative to `src/spec/`. The generated output also includes
`effective-openapi.json`, `config.json`, `provenance.json` and `diagnostics.json`.
Portable HTML and Bruno collections extend the required Markdown/fixture output.

## Backend integration boundary

The subclass and superclass prechecks are tested against the repository's
`Provider::BaseService` harness. The host application's private implementation is
not included. Runtime results use string-keyed hashes; the host must connect its
result types and operation persistence as needed.

Callback verification and status mapping work in the runtime. Backend mutation
is opt-in through `paygen_callback_result` and `paygen_backend_callback_result`.
The demo supplies this connection and checks duplicate delivery. The application
must provide durable state and idempotent mutations for multiple workers and
restarts. Provider-specific certificate or remote-key verification requires its
own implementation. See [the backend interface](architecture.md#backend-interface).

## Example coverage

| Example group | Supported claim |
| --- | --- |
| NovaPay, focused PayPal, Stripe and Adyen | Generated adapters execute against pinned, synthetic provider contracts |
| Native Paystack and PayPal | Full specifications import; selected payout flows match independent HTTP expectations |
| Raiffeisen | Full specification imports; a single-stage, non-fiscal SBP payout runs locally |
| T-Bank | Full specification imports; certificate signing and payment confirmation remain unimplemented |
| Tochka | Documentation review only; a native source was unavailable |
| 21-brand corpus | 13 native imports pass at the pinned snapshot; this count does not measure working payment integrations |

The prototype does not parse arbitrary prose or PDF documentation into an
integration. Ambiguous payment semantics require a profile. Bank sandbox
acceptance and live settlement are separate from the local test suite.
[Russian bank examples](ru-bank-examples.md) and
[provider configuration](native-onboarding.md) describe the exact supported flows.

HTTPS import preserves retrieval identity while bundling, so an absolute
self-reference to the downloaded root is rewritten to a portable local fragment
(or the internal `paygen-local:///root.json` identity where needed). Resource IDs
identify already loaded
schemas; they never grant permission to fetch arbitrary external URLs.
Regeneration therefore performs no network fetch.

## Demonstration and checks

Use [the demo walkthrough](demo.md) to generate NovaPay, inspect the service and
its guide, then exercise the adapter. The [Bruno collection](bruno-demo.md) shows
create, repeat, status, invalid authentication and callback behavior over local
HTTP. Unsupported profiles return diagnostics before executable output is written.

Run `script/check` for the full repository check: Ruby tests and CLI smoke,
dependency audits, the documentation build, Bruno regressions and container smoke
checks. It requires the installed Ruby/Node toolchains and Docker. CI runs the
Ruby suite across supported versions and retains logs and Bruno reports.
