# Verification evidence

Status: COMPLETE

Initial verified implementation and verification-script commit:
`c4097a085ff9cd4fd5491ec2248bcf96dc5a7a4c`.
[Full completion run](https://github.com/m4tveevm/paygen/actions/runs/33954587927)
completed successfully. The completion job ran `script/verify-complete` with
explicit Bash pipefail and emitted its final `PASS` JSON. The status/checklist
commit after this run records evidence; it changes no application or test code.

## Review follow-up

The ten reproduced findings in REVIEW.md are fixed with 25 additional examples.
The complete local Ruby 3.3.12 run passed **913 examples, 0 failures** (seed
19407), including the same 703 pinned RFC 9535 compliance cases. Local coverage
was 85.93% of lines and 67.14% of branches. Lint/Security checked 31 Ruby files
without offenses; the four-provider CLI smoke and architecture audit passed.

The latest commit's full remote completion gates are recorded in
[PR #1 checks](https://github.com/m4tveevm/paygen/pull/1/checks). The historical
run below predates these follow-up fixes and is not their remote evidence.

## Initial executed gates

| Gate | Result |
| --- | --- |
| Ruby 3.3.12, 3.4.10 and 4.0.6 | 888 examples, 0 failures on each version; syntax checks passed |
| Four-provider CLI smoke on every Ruby | Init, double generation, clean diff, architecture checks and generated-service verification passed |
| Offline adapter verifiers, seed 42 | NovaPay 9/9, PayPal 10/10, Stripe 11/11, Adyen 9/9 |
| Lint/Security | 30 Ruby files, no offenses |
| Ruby dependency audit | No vulnerabilities; both dependency lockfiles retained |
| Node 22/npm 11.9.0 | Strict engine installation passed; npm audit found 0 vulnerabilities |
| Documentation compatibility | 4 tests passed: parser contracts, URI decoding, Markdown rendering and XLIFF round trips |
| Diplodoc | All three documentation pages built |
| Ruby OCI | Image built and its executable doctor command passed |
| Documentation OCI | Image built, nginx started and HTTP returned the Paygen page |
| Architecture/provenance | Provider-neutral core, no unfinished/disabled mandatory tests, workflow YAML and recorded source hashes passed |

The 888 Ruby examples include 703 pinned upstream RFC 9535 compliance cases.
They are not 888 independent payment scenarios. Root's frozen local Ruby 3.3.12
run (seed 19407) independently passed all 888. Recorded local coverage was
84.75% of lines and 65.31% of branches; CLI child-process coverage is not merged
by SimpleCov.

Root independently built the gem, loaded a detached NovaPay export using its
own exported runtime (9 verifier checks), executed the Arazzo import/export/replay
example extracted from documentation, and repeated the four Node compatibility
tests and the three-page build on Node 22.22.0. A separate real Puma loopback
verifier run passed create, stable retry and status lookup.

The supplied NovaPay contract remains byte-identical to the attachment. SHA-256:
`415f50ee36fb331dfab49ceed0e8ed3b0ebe16053d7e00dbabd32282f4396551`.

## Independent audits and limits

The initial architecture, security and coverage reviews found no remaining
concrete P0/P1/P2 findings at that time. Subsequent PR review identified the ten
additional defects documented and fixed in REVIEW.md. Earlier fixes cover forged manifest
traversal, arbitrary operation-method invocation, extension export, atomic
generation, overlay symlinks, mixed-extension overlay ordering, hidden output
drift, per-operation server routing and total HTTP deadlines. A reviewer
separately passed 65 project/runtime/security/CLI regressions (seed 39674).
The completion pipeline was also reviewed for failure propagation.

Coverage limits remain in some external nested Arazzo, dependency/goto
and payload-replacement branches, actual post-swap filesystem rollback, CLI
watch, balance and HTTP-date retry parsing. These are untested branches, not
observed failures. Earlier CI runs that lacked the final PASS record are not
accepted as completion evidence.

Tests use a reference Provider::BaseService and offline provider contracts.
Real backend integration, durable payout state and PayPal's callback-verification
hook remain application responsibilities. Adyen booking intentionally does not
imply final settlement. Standards execution limits are explicit in
docs/architecture.md. Live provider certification, PCI certification, production
hosting and actual Pages deployment are outside this implementation's completion
gate.
