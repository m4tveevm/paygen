# Reproducible experiments

The research program is separate from mandatory release gates. `NOT_RUN` for an
optional comparative study does not block the prototype. A script or CI job is
not evidence of an executed PASS. Every result applies only to its recorded SHA,
dirty state and environment; a new merge SHA requires another run.

## Executable E02–E05 suite

```bash
src/run exec ruby script/research-experiments
```

The script creates `tmp/research-experiments/run-<UTC>-<pid>/` containing
`report.json`, `artifact-sha256.json`, command stdout/stderr, projects and native
RSpec JSON. An explicit **new** directory below `tmp/research-experiments/` may
be supplied; previous evidence is not overwritten. It records source and
`src/Gemfile.lock` hashes, the executed script hash, Ruby/platform/Bundler,
network/cache scope, seed, commands, exit codes and generated hashes. Environment
values and real credentials are not exported. E05 uses checked-in synthetic
HTTP expectations with WebMock, without contacting providers.

| ID | Check or oracle | Observed evidence and scope |
| --- | --- | --- |
| E01 | Full RSpec count, seed, coverage and exit status | Historical PASS: 1119/0, seed 1016 at `92ef59b…`, raw log `evidence/rspec-baseline.log`. The integrator reported a later 1141/0, seed 42570 at `09013a6…` without a retained raw log; this is not the final run. |
| E02 | Two independent project directories with the same source/profile/version produce identical generated files and hashes | PASS in E02–E05 at `954d1d1…`; see the record below. This checks independent generation, not just writing twice to one directory. |
| E03 | Equivalent YAML/JSON produce equal parsed IR, configuration, effective document and fixtures | PASS in the same run. Provenance bytes, source identity, lock bytes and `config.source_hash` are excluded from this semantic comparison. |
| E04 | Manual generated edits cause `GENERATED_DRIFT` without overwriting bytes; profile changes regenerate while preserving extensions | PASS in the same run. The extension is not executed; the control confirms changed generated artifacts. |
| E05 | Native PayPal/Paystack plus profiles preserve native sources and generate adapters checked against independent HTTP examples | PASS in the same run. Historical `git diff HEAD -- lib` and hashes showed no core edits; the current path is `src/lib/`. Covers selected create/status flows, not the entire APIs. |
| E06 | Matched-budget stateless/stateful mutation comparison | **NOT_RUN — optional future study**, not a release gate. No causal superiority of stateful fuzzing has been established. |
| E07 | Actual mutation → failure, shrink and replay; unchanged adapter passes the same trace | **OBSERVED, narrow slice:** showcase on clean `75e0331…`, seed 4242, `duplicate_payout`, trace 20 → 2 actions, mutant replay FAIL, fixed replay PASS. Not the full mutation corpus. |
| E08 | Separate cold empty-cache setup and warm CLI timings, at least five repetitions | **NOT_RUN — optional future study**, not a release gate. No measured development speedup or cold-start latency is claimed. |
| E09 | Invalid amount, recipient, schema or signature causes zero external calls or provider mutations | **PARTIAL OBSERVED:** showcase includes negative wire and callback controls, not a complete invalid-input matrix. |
| E10 | Independent regression probes A1–A5 with controls | **OBSERVED:** `script/acceptance-independent`, 6/6 on clean `b878e17…`. Post-fix probes, not a new red/green comparison of historical checkouts. |
| E11 | Documentation tests, build and static-asset validation | Commands and gates exist; a final PASS requires fresh integration logs. This research run did not execute Node, Docker or Pages. |

Full SHAs, environments and early integration-artifact hashes are in the
[observation record](evidence/INTEGRATION_OBSERVATIONS.md). A later release report
adds its final SHA and fresh logs without rewriting history. The 703 JSONPath
compliance examples in RSpec are not payment scenarios.

## Proposed E06 protocol, not yet executed

Before comparison, pin the corpus, actions, total action budget, seeds and
mutation-kill counting rule. Candidate mutations include omitted account scope,
omitted workflow dependencies, callback deduplication by mapped status alone,
decimal type drift, incorrect root-reference identity, unknown status mapped to
approval, signing reserialized bodies, unsafe create retries and disabled response
validation. These are candidates for a future protocol, not executed mutations.

Run fixed examples separately. Give stateful and stateless runs the same budget.
Count unique killed mutations and reproducible invariant violations, not
assertions. E07 validates the mechanism on one injected mutation; it does not
answer comparative research question RQ4.

## Release acceptance is separate from research

Acceptance evidence for an integrated version comprises the full RSpec suite,
independent regression probes, showcase/replay, documentation gates and required
smoke/container checks. The release report collects final statuses. Local PASS
does not replace provider sandbox verification, a private BaseService harness,
durable storage validation or PCI assessment; these experiments do not establish
those properties.
