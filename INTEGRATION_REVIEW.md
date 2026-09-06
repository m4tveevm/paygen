# Agent PR integration — 6 September 2026

The combined review surface is [PR #9](https://github.com/m4tveevm/paygen/pull/9).
Its CI and immutable run artifacts are the acceptance evidence for its current
head. An older green run is not evidence for a newer commit. Nothing in this
record authorizes merging into main or publishing Pages.

## What was integrated

| Original PR | Disposition |
| --- | --- |
| #5: live demo | Original ancestry and follow-up fixes included; actual four-profile HTTP execution, adaptation, deliberate mutation, shrinking and replay |
| #6: research | Original report included; historical and observed claims separated, E02–E05 implemented as reproducible experiments |
| #7: acceptance | Original regression corpus included; fixes implemented, independent runner added to CI, historical baseline reports retained under explicit names |
| #8: documentation | Original ancestry and follow-ups included; Ruby/Node build repaired, deterministic assets, integrity checks and explicit Pages release gate |
| #10: parallel runtime fixes | Reviewed at `101bd1b5b41a970adcaf106f11840c2854f288ab`; not merged wholesale. Its intent is covered by the stronger integrated implementation; useful negative controls are retained as tests |

## Payment and contract decisions

- The runtime option is `state_namespace`, with stable `account` as an alternative
  scope. The competing `integration_namespace` API from #10 is not introduced.
  Keys preserve exact tuple identities; secrets and delimiter substitution are not
  identity mechanisms. Changing credentials must not create a new reservation.
- An injected store requires scope before HTTP/callback effects. Recognized legacy
  scoped and unscoped keys stop execution for reviewed migration. Caller-owned
  scope strings are copied. Host durability and atomicity remain explicit duties.
- A JSON-safe private result envelope preserves public `BigDecimal` values across
  a JSON-backed store, not merely across an in-memory deep copy.
- Intermediate callback deliveries and terminal business-effect suppression are
  distinct decisions. Raw-body verification, replay checks and backend hooks remain.
- Recipient configuration uses bounded `default`, `fallback_from`, `when` and
  `fallback_conflict: reject` rules. The competing presence-based `request_variants`
  DSL is not added. NovaPay supports explicit SBP/card selection; conflicting phones
  require an explicit primary value instead of a guess.
- Optional `response_bindings` check merchant reference, provider identity, amount
  and currency before state mutation. NovaPay opts in for reference/money/currency.
  An API-valid but unrelated create response remains ambiguous and requires
  reconciliation. No undeclared binding or callback-correlation claim is inferred.
- Local retrieval filenames, shared schema resources, nested IDs and anchors
  survive supported graph serialization without suppressing genuine duplicate IDs.
  Workflow output checks cover dot/JSON Pointer forms before HTTP; descriptions are
  not executed. Cross-workflow outputs require explicit prerequisites.
- Detached exports include shared helpers and are executed without the source
  runtime on the load path. Vendored third-party gems remain available to that test;
  removing an exported helper is a failing negative control.

## Why #10 is not merged directly

Differential probes reproduced namespace delimiter collisions, equal provider keys
across distinct namespaces, account collisions inside a namespace, an unscoped
cancel reaching HTTP, and decimal type drift in a JSON-backed store on #10. Its
workflow scan also treats prose as executable references. These are not reasons
to discard its intent: they explain why one coherent runtime contract and extra
regression controls were chosen instead of overlaying two implementations.

Its partial HTTPS retrieval-identity fix is not complete across project import and
serialization. That limitation is documented rather than promoting a one-call
success to a universal-import claim.

## Reproduce and inspect

```bash
bundle exec rspec
bundle exec ruby script/acceptance-independent
examples/showcase/run tmp/showcase-new
bundle exec ruby script/research-experiments
npm run docs:test
npm run docs:build
script/check
```

Use the locked Ruby/Node toolchains described in `docs/development.md`. The last
command also requires Docker. CI runs Ruby 3.3.12, 3.4.10 and 4.0.6, full OCI Ruby
tests, independent acceptance, the OCI showcase and a real `/paygen/` docs-server
check with a negative 404 control. Evidence is retained in GitHub Actions artifacts,
including failures; local command output is below ignored `tmp/`.

Observed local integration at `30cfb6efd4eb2c6f92e3b43b2c2c54638ae7883c`:
1192 RSpec examples, zero failures, seed 424242; independent acceptance 6/6;
research E02–E05 4/4. The second showcase at `80f5cc6` passed 150 checks, including
one actual 20→2 mutation/replay sequence. Two docs builds at `30cfb6e` had identical
97-file manifests. These counts are bounded observations, not a sum of independent
payment scenarios or a declaration that later revisions are automatically green.

## Publication and remaining boundaries

The website publishes only static documentation and synthetic, redacted downloads.
Generated and published hashes are recorded separately; redaction never changes
functional runtime identity fields. Deployment is explicit, after integrated CI,
reviewed artifact digest and the protected GitHub Pages environment approval.

No PSP sandbox/settlement, arbitrary application installation, private production
BaseService, production durable-store exactly-once contract or PCI certification is
claimed. The matched-budget fuzzing comparison and cold-start timing study remain
optional NOT_RUN research, not fabricated acceptance results.
