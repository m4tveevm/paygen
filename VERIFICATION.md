# Verification evidence

Status: CONTINUE — final combined CI and OCI gates pending.

## Executed Ruby and product checks

Implementation commit: `61ebcedb31fd76290fbce9b458a6533e991d2d62`.
Bundler and lockfile integration commit: `0d3944d04b6b8e7140faace3be504d3f593a45ec`.
[CI matrix run](https://github.com/m4tveevm/paygen/actions/runs/33953811838)
proved 888 examples / 0 failures on each of Ruby 3.3.12, 3.4.10 and 4.0.6.
Each version also passed `script/smoke`: deterministic double generation, clean
diff, generated-service loading and four real adapter verifiers (NovaPay9,
PayPal10, Stripe11, Adyen9 checks).

The 888 examples include 703 pinned upstream RFC9535 compliance cases. They
are not 888 independent payment scenarios. Root's frozen local Ruby3.3.12 run
(seed19407) also passed all888, followed by Lint/Security (30files, no offenses)
and the architecture/provenance audit. Recorded local coverage: 84.75%lines
and65.31%branches; CLI child-process coverage is not merged by SimpleCov.

Root independently built the gem, loaded a detached NovaPay export using its
own exported runtime (9 verifier checks), and executed the Arazzo import/export
/replay example extracted from documentation. The supplied NovaPay contract is
byte-identical to the attachment, SHA256:
`415f50ee36fb331dfab49ceed0e8ed3b0ebe16053d7e00dbabd32282f4396551`.

## Independent audits

Architecture, security and coverage review found no remaining concrete P0/P1/P2
in the inspected scope. Confirmed fixes cover forged lock traversal, arbitrary
operation-method invocation, extension export, atomic generation, overlay
symlinks, global mixed-extension overlay ordering, hidden generated-file drift,
per-operation server routing and total HTTP deadlines. The reviewer separately
ran project/runtime/security/CLI regressions:65 examples,0failures(seed39674).

Coverage limits remain in external nested Arazzo execution, some dependency/goto
and payload-replacement branches, actual post-swap filesystem rollback, CLI
watch, balance and HTTP-date retry parsing. They are not observed failures.
Actual Puma loopback verification was executed separately from mocked tests.

## Documentation dependency verification

Node 22.22.0 with npm 11.9.0 passed a fresh installation with strict engine
checks. Both agent and root executed four compatibility regressions and built
all three documentation pages. npm audit reported zero vulnerabilities, with
no exclusions. Ruby Bundler Audit also reported no vulnerabilities using advisory
database commit `bc85cccbbc0a7cf14818d34413c56b8141b83a45`.

## Remaining completion gate

Run `script/verify-complete` with the final committed dependency graph and record
the exact successful CI run. It must pass Ruby tests, Lint/Security, Bundler Audit,
four-provider smoke, architecture audit, npm audit, Diplodoc build, Ruby OCI
startup and a served documentation OCI HTTP response. Earlier runs are not
completion evidence: dependency findings and a pipeline that masked a failing
exit were corrected. The final gate requires explicit Bash pipefail and the
script's terminal PASS record, followed by a successful CI job.

## Scope of the result

Tests are offline and use a reference Provider::BaseService. Real backend
integration, durable payout state, PayPal callback verification hook, live
provider certification and production deployment require application work.
Adyen booking intentionally does not imply final settlement. Standards execution
limits are explicit in docs/architecture.md. No live payout or actual Pages
deployment is part of this evidence.
