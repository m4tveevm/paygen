# Independent hard-acceptance corpus

This directory is owned by role 06 and deliberately does not derive its wire
expectations from generated fixtures or the simulator. Run the finite baseline
regression slice with:

```sh
bundle exec ruby script/acceptance-independent
```

The runner writes `acceptance/independent/reports/latest.json` and exits nonzero
when a requirement is violated. A failing acceptance run is evidence, not a
reason to weaken the oracle. The checked-in report records the tested revision;
regenerate it after an implementation fix and review both expected and observed
fields before accepting it.

| ID | Source | Independent expectation | Severity |
| --- | --- | --- | --- |
| Q3-TENANT-NIL-001 | [PROJECT POLICY] Q3 isolation | An unscoped integration identity is rejected before an outbound write; distinct credentials cannot share a cached payout. | P1 |
| Q5-PREFLIGHT-OUTPUT-001 | [PROJECT POLICY] Q5 workflow preflight | Explicit and implicit references to missing step outputs fail before HTTP. | P1 |
| Q4-PROGRESS-EVENT-001 | [CASE/Q&A] status mapping; [PROJECT POLICY] Q4 lifecycle | Distinct signed `pending` then `processing` events remain distinct progress evidence and update metadata. | P2 |
| Q2-DECIMAL-CACHE-001 | [PROJECT POLICY] Q2 exact money | A decimal response has one stable public Ruby type and exact value on first and cached reads. | P2 |
| Q1-ROOT-BACKREF-001 | [PROJECT POLICY] Q1 local references | A child schema can refer back to the actual root filename without creating an artificial duplicate resource ID. | P2 |

Scope is intentionally finite: these five cases reproduce the five known
baseline risks on `92ef59bc2c8eb102c7452136ee4ea8a46887fd52`. They are not a
claim that Q0--Q8, OCI, the full fuzz budget, Pages, or a production
`BaseService` harness have been accepted.
