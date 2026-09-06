# Claim register

This historical register refers to baseline
`92ef59bc2c8eb102c7452136ee4ea8a46887fd52`. Source paths and line numbers below
refer to that snapshot unless another revision is specified. Current Ruby source
and tests live in `src/lib/` and `src/spec/`. Current reproduction commands are in
[EXPERIMENTS.md](EXPERIMENTS.md) and the [development guide](../docs/content/development.md).

| Claim ID | Statement | Type | Source or implementation | Evidence | Limitation |
| --- | --- | --- | --- | --- | --- |
| C01 | The product and generated service use Ruby; ML inside the product is prohibited. | REQUIREMENT | [CASE], original task assignment | Prompt summary | Permission for a development agent was not separately established. |
| C02 | `request_method` denotes a logical gateway action, not an HTTP verb. | REQUIREMENT | [Q&A] | Prompt summary | Payment method and HTTP method are separate concepts. |
| C03 | NovaPay HMAC-SHA256 signs the exact raw body and places a hexadecimal signature in a header. | REQUIREMENT | [Q&A] | Prompt summary | Requires a host hook carrying raw bytes and headers. |
| C04 | OpenAPI describes operations, parameters, security and schemas, but does not guarantee domain semantics. | NORMATIVE + INFERENCE | OAS 3.0.3/3.1.1; paper §3 | SOURCES 1–2 | The second part is an inference, not a standards quotation. |
| C05 | Overlay actions are applied separately from the immutable source snapshot. | IMPLEMENTED | `lib/paygen/core/overlay.rb`, `project.rb` at baseline | RSpec baseline log | Only the documented subset and limits are implemented. |
| C06 | Provenance records the winning semantic source. | IMPLEMENTED | `lib/paygen/core/ir.rb:33–36,376–382` | RSpec baseline log | Ruby Hash representation is not an immutable typed IR. |
| C07 | Generated-file drift blocks regeneration; extensions are preserved. | IMPLEMENTED | `lib/paygen/generator.rb:48–50,105`; project specs | RSpec baseline log | The host must explicitly load extensions. |
| C08 | Money conversion uses BigDecimal. | IMPLEMENTED | `lib/paygen/runtime/adapter.rb:343–357,524` | RSpec baseline log | Scale and precision remain semantic policies. |
| C09 | Callback verification accepts raw body/headers and rejects unverifiable callbacks by default. | IMPLEMENTED | `lib/paygen/runtime/adapter.rb:98–111,162–169`; docs generator | RSpec baseline log | Production BaseService integration has not been verified. |
| C10 | Product StateFuzzer implements its own generation, shrinking and replay; PropCheck is used separately. | IMPLEMENTED | `lib/paygen/runtime/state_fuzzer.rb`; `spec/runtime_adapter_spec.rb:459–461` | RSpec baseline log | The implementation is not attributed to QuickCheck. |
| C11 | Full baseline suite: 1119/0, seed 1016, 89.46% line and 74.76% branch coverage. | OBSERVED | Baseline SHA | `evidence/rspec-baseline.log` | 703 examples are JSONPath compliance cases, not payment scenarios. |
| C12 | Localhost HTTP execution does not prove provider sandbox acceptance or settlement. | INFERENCE | Threat model, paper §§6–7 | Architecture and test setup | External verification is required. |
| C13 | A shared generator reduces accidental drift between code, docs and fixtures. | INFERENCE | Paper §§4–5 | C06–C07; proposed consistency experiment | Shared semantic mistakes remain possible. |
| C14 | The default in-memory store does not provide cross-process exactly-once behavior. | INFERENCE | Runtime architecture; paper §§2,7 | Code review | Durability, crash and transaction contracts are required. |
| C15 | Six independent probes of five baseline defects A1–A5 pass on clean `b878e17…`. | OBSERVED | `script/acceptance-independent` | `evidence/INTEGRATION_OBSERVATIONS.md`: 6/6 and raw-report hash | A post-fix slice, not a full red/green study or a claim about later SHAs. |
| C16 | Final release acceptance and optional research are tracked separately. | PROJECT POLICY | `EXPERIMENTS.md` | E06/E08 explicitly NOT_RUN; each final release report adds its own SHA | Neither completion of all studies nor all-green CI is claimed. |
| C17 | OAS 3.1 Schema Object aligns with a JSON Schema dialect; OAS 3.0 uses a different dialect. | NORMATIVE | OAS 3.0.3/3.1.1, JSON Schema 2020-12 | SOURCES 1–3 | Validator configuration must account for the version. |
| C18 | Encrypting cardholder data alone does not remove PCI scope. | NORMATIVE | PCI SSC FAQ 1086 | SOURCES 11 | Actual scope depends on architecture and assessment. |
| C19 | E02–E05 executed independent byte equality, semantic YAML/JSON equality, drift/extension preservation and native onboarding without core edits. | OBSERVED | `script/research-experiments` at `954d1d1…`, with script hash | `evidence/INTEGRATION_OBSERVATIONS.md`; raw report under `tmp/research-experiments/` | Dirty research/script state was recorded; neither final-SHA evidence nor arbitrary-provider support. |
| C20 | Showcase produced 150 PASS checks on clean `75e0331…`. | OBSERVED | `examples/showcase/run` | `evidence/INTEGRATION_OBSERVATIONS.md`: summary, hash and environment | Count includes commands and assertions, not 150 independent payment scenarios. |
| C21 | One actual mutant failure shrank from 20 to 2 actions and replayed; the ordinary adapter passed the same trace. | OBSERVED | `examples/showcase/mutation.rb`, StateFuzzer, seed 4242 | E07; mutant-failure/replay/fixed-replay hashes | No matched-budget control or causal claim of superiority over stateless testing. |
| C22 | An additional suite completed with 1141/0, seed 42570 at `09013a6…`, before later changes. | REPORTED | Integrator message | No retained raw log from the intermediate session | Not archived evidence for the final SHA; the final run needs a log. |
