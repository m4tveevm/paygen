# Payment verification

Paygen uses several checks with different scopes:

| Check | What it establishes |
| --- | --- |
| `verify` | Adapter behavior against the configured simulator, including faults and response contracts |
| Direct simulator tests | Invalid request bodies, parameters and media types are rejected before creating a payment |
| Independent transport tests | A provider ignoring or expiring keys cannot cause unsafe retries; malformed responses cannot approve a payment |
| `fuzz` | Generated action sequences preserve commit count, identity and state invariants |
| Bruno | Requests traverse the local HTTP application, generated adapter and simulator |
| Native contract tests | Selected request/response pairs match independently defined provider examples |

These checks run locally with synthetic data. They do not establish bank sandbox
acceptance, production database behavior or compatibility with a private backend.
The Ruby test count also includes 703 upstream JSONPath compliance cases; it is
not a count of payment scenarios.

## Generate payment sequences

Start with an existing, up-to-date generated project:

```bash
bundle exec src/bin/paygen fuzz tmp/novapay --seed 42 --cases 100 --steps 30 \
  --output tmp/novapay-fuzz.json
```

Each sequence uses a fresh adapter state and an adversarial local provider. Its
actions include creation, retry, polling, signed callback delivery, logical
duplicate callbacks, stale updates, cancellation and time advancement. Fault
modes exercise lost responses, provider-key expiry, numeric identifiers and
invalid successful responses.

The report counts executed actions, injected faults, checked invariants and
skipped capabilities. Profiles without callbacks or cancellation explicitly skip
those actions. A successful report applies only to the sequences it executed.

Limits are 1,000 cases, 100 steps per case and 10,000 steps in total. The output
file must be new, its parent directory must exist, and it must be outside the
generated project.

## Replay a failure

On failure, `fuzz` returns exit code 1 and saves both the original `trace` and a
smaller `shrunk_trace`. Shrinking removes actions while retaining the same failed
invariant, with a bounded number of attempts. Replay the saved failure report:

```bash
bundle exec src/bin/paygen fuzz tmp/novapay --replay tmp/novapay-fuzz.json
```

Replay prefers `shrunk_trace`. The trace records the seed, mode, actions and
configuration digest. A malformed trace or different integration configuration
is rejected before execution. After changing adapter code, replay with the same
profile to check whether the failure is fixed; regenerate the project first.

The fuzzer observes actual provider commits, returned identities and callback
hook calls. It does not inspect the adapter's internal replay ledger to decide
whether a property passed. Wire samples still come from the profile, so native
contract tests remain a separate check.

## Reproducible showcase and deliberate failure

From a checkout with `bundle install` completed, run:

```bash
examples/showcase/run tmp/showcase
```

The output directory must be new. The launcher starts and stops only its own
loopback processes. It records commands, source identity, artifact hashes and
assertions for four provider profiles, malformed HTTP requests, profile/Overlay
adaptation and generated-file ownership. A disposable subprocess deliberately
breaks reservation retention, obtains a real duplicate-commit failure, shrinks
it, replays the failure, and replays the same trace against the unchanged runtime.
The expected mutant failure is a successful test only when the failure and fixed
control both satisfy the declared checks. No mutation is installed in the product.

This is a bounded demonstration, not a benchmark proving superiority over all
stateless fuzzers. It does not connect to a user's installation or a PSP sandbox.

## CI

The Ruby matrix runs unit, contract, lifecycle and standards tests. Provider smoke
checks also run seeded sequences for NovaPay and Raiffeisen. The integration job
runs Bruno, the independent regression acceptance, full Ruby tests and the
showcase inside the Ruby container. `script/acceptance-independent` can also be
run locally; it writes a fresh report below `tmp/acceptance-independent/`.

CI retains verification logs, fuzz reports and Bruno JSON/JUnit reports, including
failed runs. A successful retry of CI does not invalidate an earlier failure;
use the saved responses and replay trace to investigate it.
