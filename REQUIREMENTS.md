# Requirements and traceability

Sources: user-supplied PLAN.md (preserved in automation/ORIGINAL_PLAN.md),
provider_api.yaml (byte-identical fixtures/novapay/openapi.yaml) and the case PDF.

| Requirement | Implementation/evidence |
| --- | --- |
| Ruby majority; no runtime neural network; open source | lib/, gemspec, LICENSE |
| Parse methods, parameters, responses, auth and webhook | core/input.rb, core/ir.rb, input specs |
| Generate BaseService integration and fixtures/guide | generator.rb, packs specs |
| Explicit ambiguity, configurable mappings | integration.yml profiles, IR diagnostics |
| Four provider-neutral offline packs | fixtures/, recipes/, packs specs |
| Stable regeneration, drift, extensions | project.rb, generator specs |
| Full Overlay 1.1 and RFC9535 | core/overlay.rb, overlay specs, Janeway |
| Arazzo 1.1 structural validation and payout execution | core/workflow.rb, workflow specs |
| Payout runtime, mocks, verifier and boundary fuzz | runtime/, runtime specs |
| Safe input, refs, paths, requests, signatures/redaction | input/runtime security specs |
| OCI Ruby image, CI matrix | Dockerfile, .github/workflows/ci.yml |
| Diplodoc + Pages workflow + local server | package.json, docs/, Dockerfile.docs |
| Completion/recovery records | automation/, IMPLEMENTATION_STATUS.md, VERIFICATION.md |

Full original-plan completion additionally requires executed standards compatibility,
all tests, all adapters loaded, independent audit with P0/P1 fixed, OCI smoke,
documentation build and dependency audit. Unsupported behavior must fail explicitly.
No unsupported claim or unexecuted gate may be marked COMPLETE.
