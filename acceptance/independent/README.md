# Independent hard-acceptance corpus

This directory is owned by role 06 and deliberately does not derive its wire
expectations from generated fixtures or the simulator. Run the finite baseline
regression slice with:

```sh
bundle exec ruby script/acceptance-independent
```

The runner writes `tmp/acceptance-independent/latest.json` and exits nonzero
when a requirement is violated. A failing acceptance run is evidence, not a
reason to weaken the oracle. `PAYGEN_ACCEPTANCE_REPORT` can select a separate
output file. Checked-in `reports/baseline-92ef59b.*` are historical failing
evidence, never the latest verdict. New reports record the tested SHA and are
uploaded by CI without modifying source files.

The shared-store contract now rejects both unscoped instances before HTTP,
rather than allowing a first unscoped write and rejecting only the second.
The original oracle overconstrained that implementation detail. A separate
positive control verifies distinct scoped accounts and credential rotation;
rejecting all integrations cannot make the suite pass.

| ID | Source | Independent expectation | Severity |
| --- | --- | --- | --- |
| Q3-TENANT-NIL-001 | [PROJECT POLICY] Q3 isolation | An unscoped integration identity is rejected before an outbound write; distinct credentials cannot share a cached payout. | P1 |
| Q3-TENANT-SCOPED-002 | [PROJECT POLICY] Q3 isolation and rotation | Distinct accounts create distinct operations; credential rotation retains the correct cached operation. | P1 |
| Q5-PREFLIGHT-OUTPUT-001 | [PROJECT POLICY] Q5 workflow preflight | Explicit and implicit references to missing step outputs fail before HTTP. | P1 |
| Q4-PROGRESS-EVENT-001 | [CASE/Q&A] status mapping; [PROJECT POLICY] Q4 lifecycle | Distinct signed `pending` then `processing` events remain distinct progress evidence and update metadata. | P2 |
| Q2-DECIMAL-CACHE-001 | [PROJECT POLICY] Q2 exact money | A decimal response has one stable public Ruby type and exact value on first and cached reads. | P2 |
| Q1-ROOT-BACKREF-001 | [PROJECT POLICY] Q1 local references | A child schema can refer back to the actual root filename without creating an artificial duplicate resource ID. | P2 |

Scope is intentionally finite: six cases cover the five known baseline risks
and a positive isolation/rotation control. The original five-case report was
captured on `92ef59bc2c8eb102c7452136ee4ea8a46887fd52`. These probes are not a
claim that Q0--Q8, OCI, the full fuzz budget, Pages, or a production
`BaseService` harness have been accepted.
