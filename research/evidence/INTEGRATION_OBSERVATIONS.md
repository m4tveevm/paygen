# Integration observations — 6 September 2026

This register describes **separate executed runs**, not a final-merge PASS. The
historical baseline logs in this directory are unchanged. The raw integration
artifacts listed below were read locally but reside in ignored `tmp/` directories
of their respective checkouts; **this document does not include them in Git**.
A hash identifies inspected bytes but does not replace an archive. Preserve the
evidence directories or rerun commands and attach fresh logs before handing over
results. Counts from different runs must not be added together.

Commands below retain the form executed at their recorded historical SHAs.
For the current checkout, use `src/run exec ruby script/acceptance-independent`
and `src/run exec ruby script/research-experiments`; see the
[development guide](../../docs/content/development.md) for setup.

## Historical baseline and intermediate suite

- Archived baseline: `92ef59bc2c8eb102c7452136ee4ea8a46887fd52`,
  RSpec 1119/0, seed 1016; Linux x86_64, Ruby 3.4.4. See `rspec-baseline.log`
  and the existing `SHA256SUMS`. This is not a new check of the current version.
- REPORTED by the integrator: `09013a6fb28ac258724c680eebb561901a64867f`,
  RSpec 1141/0, seed 42570, before subsequent card, demo and other fixes.
  The intermediate raw log was not retained; do not present it as an archived PASS.

## E10: independent regression acceptance

- Source SHA: `b878e17f87939f834872fced178b3d3f768cceab`, dirty state: clean.
- Command: `bundle exec ruby script/acceptance-independent`.
- Ruby 4.0.6, arm64-darwin25; injected transport, no provider network.
- Observed: 6 executed, 6 passed, 0 failed/skipped/blocked. Mutation controls
  in this report are NOT_RUN; the separate showcase below checks its own mutation.
- Raw artifact: `paygen-integration/tmp/acceptance-independent/latest.json`.
- SHA-256: `41b6c96c378989087938f8af3b9eeb95bf3984b2e08f9982a20789a435087a37`.

The probes cover tenant namespaces and scoped credential rotation, output-reference
preflight before HTTP, distinct progress events, decimal cache types and root
filename back-references. This is a post-fix slice, not renewed red/green evidence
for each historical defect or a private-backend guarantee.

## E07 / E09 slice: executed showcase

- Source SHA: `75e033165ff19ebb96c4d5bde0c491ed627264b7`, dirty state: clean.
- Command: `examples/showcase/run tmp/integrated-showcase-1`.
- Ruby 4.0.6, Bundler 4.0.20, arm64-darwin25, synthetic loopback only, seed 4242.
- `summary.json`: status PASS, 150 checks, all PASS. This count includes commands
  and assertions, not 150 independent payment scenarios.
- Mutant: `success: false`, invariant `duplicate_payout`, 20 actions → 2 actions,
  13 shrink attempts. Persisted mutant replay again returned `success: false`
  for the same invariant. Fixed replay: `success: true`, 2 actions.
- All three reports have the same profile SHA:
  `afaea48b6e6ec1cd703204d8940fce869a8d103cec792bc05367d373b6abf8b0`.
- Raw directory: `paygen-integration/tmp/integrated-showcase-1/`.

| Raw file | SHA-256 |
|---|---|
| summary.json | `7c2afd5e0a6e58e7a3393b39b125b5ccdcdd4ef641ed960176a01368b15544c1` |
| tested-sha.txt | `53d8003c11d8f2ab9a2bdb477a54b21802020bba3e0b3ce16dac052bdaa7f271` |
| dirty-state.txt | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| environment.json | `71b88b25652fa5dceb6fa950759c29d0a49bbd16fbcc9f5ea2cd0e774f7f1624` |
| mutant-failure.json | `6911b83f090d1100ec58a3c7ac92999d81f3913f975ebe029ace6abb00b81f3d` |
| mutant-replay.json | `759d8bf8cfc689ab1c93015f5f8688cc59170f1d845a993d2e84f93d5cc48a69` |
| mutant-trace.json | `62fbcbf96c4016dc267a31617a778118d5ff4f38af8666e0f8ac38fd0c8193f3` |
| fixed-replay.json | `5f8af7907397744875e685b816d510302dc72a6d03beb3272e889e8f549b5e27` |

One deliberate mutation establishes this negative control, shrinking and replay;
it does not establish a full-corpus mutation kill rate or a matched-budget
advantage. The showcase also checks a subset of invalid wire and callback cases,
not all possible states.

## E02–E05: first research run

- Source SHA: `954d1d19f1d6487e3d872a7d89d709fba16056e9`.
- Dirty state: only the new `script/research-experiments`; core was clean and
  remained byte-identical. This predates script formatting and research-doc edits.
- SHA-256 of the executed script bytes:
  `58cc20aa9511586e27e2741e0b5aa3510fb51e4e5a691cb7afbd10a2d3914009`.
- Command: `bundle exec ruby script/research-experiments`.
- UTC: `2026-09-06T09:04:35Z` — `2026-09-06T09:04:43Z`.
- Ruby 4.0.6, Bundler 4.0.20, arm64-darwin25, existing dependency cache,
  local files and WebMock; no Node or container execution; native RSpec seed 42.
- E02: PASS, 7 generated files in each of two independent directories.
- E03: PASS, compared parsed IR/configuration/effective document/fixtures.
- E04: PASS, drift refusal preserved manual edits; a real profile change altered
  generated outputs and retained the user-owned extension without executing it.
- E05: PASS, native PayPal/Paystack create/status; native RSpec 14 examples,
  0 failures, 0 pending, 0 errors outside examples; core unchanged.
- Raw directory:
  `paygen-research/tmp/research-experiments/run-20260906T090435-26580/`.
- `report.json` SHA-256:
  `5e502061481d0d0567caa97367ae0a0a147a88011331315eeb8d6c15c8140ec3`.
- `artifact-sha256.json` SHA-256:
  `9f230cbdae68009f6602aef1139bffca46c55f01a30d6679b30dba5594cbb6e3`.

The script executes the finite E02–E05 suite and saves new hashes for each run.
E06/E08 are explicitly NOT_RUN. The final integrator reruns the suite after
assembling the release SHA; this initial report is not relabeled as final.
