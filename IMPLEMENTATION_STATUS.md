# Implementation status

Status: COMPLETE

## Native onboarding and integration bundles

The approved follow-up is implemented in
[PR #2](https://github.com/m4tveevm/paygen/pull/2). Its implementation commit
`66847cb8f35bb25ce1045b2fff772706db67f387` passed the full
[completion run](https://github.com/m4tveevm/paygen/actions/runs/33959385178).

Delivered: bounded full-spec import, guided explicit profiles, PDF backend seam,
query/header mappings, exact JSON amounts, conservative retry/reconciliation,
portable MD/HTML, complete examples, effective OpenAPI, Bruno and a local adapter
application. Three full native contracts have independent replay cases;
Russian examples include Raiffeisen, T-Bank and a Tochka source-unavailable review.

All three Ruby versions passed 1,017 examples. Seven profiles passed CLI smoke;
Bruno passed 56 loopback requests and 88 assertions. Audits, six documentation
pages and both OCI checks passed. NATIVE_ONBOARDING_PLAN.md records scope and
remaining product boundaries; VERIFICATION.md records exact evidence.

## Initial reference implementation

The initial full reference implementation and all completion gates passed for commit
`c4097a085ff9cd4fd5491ec2248bcf96dc5a7a4c` in
[CI run 33954587927](https://github.com/m4tveevm/paygen/actions/runs/33954587927).

Delivered: Ruby CLI and gem, OpenAPI/Overlay/Arazzo processing, deterministic
generation and export, declarative profiles/recipes/hooks, four offline provider
packs, payout runtime and simulator/verifier, security regressions, Node 22
Diplodoc documentation, both OCI images and manual Pages workflow.

That run passed 888 examples on all three Ruby versions; four documentation
compatibility tests, dependency audits and both container checks passed.
`script/verify-complete` emitted its final PASS record.

Subsequent PR review found ten reproducible defects in authentication, source
identity, server URLs, callback/transport handling and workflow execution. All
ten are fixed with regression coverage; see REVIEW.md for the findings and
VERIFICATION.md for follow-up results. Current branch checks are available on
[PR #1](https://github.com/m4tveevm/paygen/pull/1/checks).

Evidence and coverage limits are recorded in VERIFICATION.md. The automation
checklist is complete. PR #1 contains the reviewable implementation. Future
backend integration and any deployment are separate application work under the
scope recorded in the original plan.
