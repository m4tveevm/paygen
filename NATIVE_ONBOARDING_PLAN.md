# Native API onboarding and usable integration output

Status: CONTINUE

Approved scope: close the gaps found in the PDF assessment, accept full native
OpenAPI sources, guide unfamiliar-provider configuration, generate portable
documentation and Bruno examples, and add Russian bank examples from official
sources. Work is based on merged PR #1 (`a2e787a1`).

1. Preserve bounded reference graphs and expand selected operations; retain
   explicit diagnostics for invalid documents and unsupported selected schemas.
2. Match the PDF backend seam, including inherited prechecks,
   `provider_operation_id`, and opt-in callback persistence.
3. Support declared query/header parameters and guided semantic configuration.
4. Generate useful Markdown/HTML, effective OpenAPI, named/signed fixtures and
   Bruno collections; demonstrate the generated adapter through local HTTP.
5. Verify independent native specifications and Russian bank examples. Report
   payout, acquiring, bank-transfer and unsupported cases separately.
6. Run focused regressions, independent audits and the complete CI gate; open a
   separate PR. No merge, deployment or live payment is part of this work.

Evidence and remaining limitations will be recorded here before completion.

## Implemented and locally verified

- Bounded graph import, selected endpoint expansion, relative OAuth URLs and
  literal schema examples; explicit diagnostics for unsupported selected graphs.
- `configure`, profile input, role evidence, nested profile validation, generic
  query/header mappings, inherited backend checks and callback persistence seam.
- Exact decimal JSON numbers, conservative reconciliation and provider identity
  binding; audit fixes for header ambiguity and transport control headers.
- Portable MD/HTML, effective OpenAPI, complete named examples and independently
  checked signed callback fixtures; Bruno collection and local adapter demo.
- Full native Paystack, PayPal and Raiffeisen adapters with independent HTTP
  oracles; T-Bank signing/workflow and Tochka source-availability counterexamples.
- Corpus: 21 digest-pinned native specifications, 13 successful imports.
- Full local Ruby suite: 1,017 examples, zero failures; subsequent focused
  regressions cover the final simulator/CLI changes. Mandatory final CI remains.
- Ruby dependency audit and documentation dependency audit: no advisories.
- Isolated, pinned Bruno 4.1.0 with patched dependencies: no advisories;
  5 runs across 4 profiles, 56 real loopback HTTP requests, 88 assertions pass.
- Independent audits covered input/profile semantics, callback/backend boundaries,
  strict retry state, ID binding, headers and local export paths. Reproduced
  findings have fixes and regression coverage.

Remaining completion work: publish the review branch/PR, run the complete Ruby
matrix and OCI/Bruno completion gate on GitHub, then record its exact evidence.
Bank admission/live acceptance, T-Bank certificate signing and selected recursive
schemas remain explicit product boundaries, not claimed successes.
