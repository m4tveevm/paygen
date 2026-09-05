# Full-plan completion gates

- [ ] Ruby 3.3.12, 3.4.10 and 4.0.6 full suite passed.
- [ ] All four generated adapters syntax-check, load and pass golden scenarios.
- [ ] Byte-identical regeneration, stale overlays, drift and extensions verified.
- [ ] Overlay1.1 and RFC9535 compatibility suite passed.
- [ ] Arazzo1.1 validation and payout workflow replay passed.
- [ ] Timeout, idempotency, callback ordering/rotation, 429, unknown states,
      batch item failure and late payout reversals verified.
- [ ] SSRF, refs, YAML/path/template injection and redaction verified.
- [ ] Independent architecture, security and coverage audits completed; no P0/P1.
- [ ] Dependency audit passed; lockfiles retained.
- [ ] Diplodoc static build and local OCI server smoke passed.
- [ ] Ruby OCI smoke passed and Pages workflow is structurally valid.
- [ ] No skipped tests, TODO/NotImplementedError or blocking diagnostics in
      mandatory paths. Core has no provider-specific names or branches.
- [ ] script/verify-complete completed and exact evidence recorded.

Actual public Pages URL, production hosting, real provider calls, PCI certification
and a universal AsyncAPI broker executor are outside the completion gate.
