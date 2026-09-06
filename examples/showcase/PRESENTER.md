# Paygen presenter pack

Every statement below carries its requirement source. The live environment is
synthetic and loopback-only; JSON responses, not narration or UI color, are the
observable result.

## Two-minute pitch

1. **0:00–0:25 — contract to reviewable facts.** [CASE] Show
   `novapay-inspect.json`, then the pinned source and `novapay-artifact-sha256.json`. Paygen reads
   OpenAPI plus explicit integration decisions; it does not use an LLM or claim
   to infer every payment semantic.
2. **0:25–0:55 — generated delivery.** [CASE] Open
   `generated/novapay_service.rb`, `INTEGRATION.md`, `fixtures.json` and
   `config.json`. Point out `Provider::NovaPayService < Provider::BaseService`,
   exact minor-unit conversion, API-key configuration and status mapping.
3. **0:55–1:35 — real local call.** [PROJECT POLICY] Open the panel, create and
   retry one operation, then refresh evidence. The same provider ID and a commit
   delta of one demonstrate this adapter/simulator contract—not settlement.
4. **1:35–2:00 — failure evidence and scope.** [Q&A] Submit invalid then valid
   callback; show HTTP status and backend-effect delta. Close with drift refusal,
   semantic adaptation, a real mutant/fixed replay comparison, and HTTP evidence
   from four generated providers.

Fallback: if the browser is unavailable, run `examples/showcase/run` and show its
saved JSON. If startup fails because the port is occupied, choose another with
`PAYGEN_DEMO_PORT`; never kill the unknown listener.

## Seven-minute walkthrough

| Time | Show / command | Observable result | Criterion and fallback |
| --- | --- | --- | --- |
| 0:00–1:00 | `examples/showcase/run tmp/live` | Fresh `inspect`, `init`, `configure`, `generate`; second generation and `diff --check` pass | [CASE] API analysis and sequential launch. Fall back to the command log. |
| 1:00–2:00 | Generated service/docs/fixtures/config and hashes | Ruby syntax pass, inheritance and endpoint roles in actual files | [CASE] service and generated deliverables. Use terminal `sed` if no editor. |
| 2:00–3:30 | Start `src/run cli demo tmp/live/novapay --port 9293`, then open its panel | Server response contains provider ID; evidence commit delta is one | [PROJECT POLICY] generated adapter really executes. Use saved `novapay-run-*-*.json`; do not interact during the automated run. |
| 3:30–4:30 | Invalid/valid callback reports | 422/no effect, then 200/terminal backend effect; HMAC independently checked with OpenSSL | [Q&A] exact raw-body HMAC. Use report JSON. |
| 4:30–5:15 | `adaptation.json`, `adapt-old-minimum.json`, `adapt-new-minimum.json`, `drift-refusal.stderr` | Profile + Overlay changes executable minimum; source stays pinned, user extension survives; managed edit is refused | [PROJECT POLICY] synthetic contract adaptation, not a real provider contract change. |
| 5:15–6:00 | `mutant-failure.json`, `mutant-replay.json`, `fixed-replay.json` | Failing trace is reduced and fails again; identical trace/profile passes with the unmodified adapter | [PROJECT POLICY] disposable mutant, bounded shrink/replay, no product bypass flag. Read actual lengths from the reports. |
| 6:00–7:00 | `stripe-run-0-*`, `paypal-run-0-*`, `adyen-run-0-*`, `wire-*.json` | Four executed adapter contracts plus independent HTTP schema-negative controls | [Q&A] independent core and explicit profiles. PayPal is fail-closed; Adyen `booked` is not approval. |

## Fifteen-minute technical walkthrough

Use the seven-minute flow, then spend two minutes each on: (1) profile provenance
and unresolved semantics in `novapay-configure.json`; (2) exact money and response-schema
validation in generated code; (3) raw callback bytes, headers, duplicate/stale
state boundaries; and (4) evidence deltas across the three sessions plus fuzz
coverage. Finish with the limits below. Commands remain the launcher commands so
the longer version does not introduce an untested manual path.

## Questions and honest boundaries

**Why not just an SDK generator?** [PROJECT POLICY] An SDK exposes HTTP methods.
Paygen adds explicitly reviewed payment semantics, backend lifecycle hooks,
failure policy, reproducible fixtures and verification evidence.

**What is automatic and what is manual?** [CASE/Q&A] Supported OpenAPI dialects,
local references and known profiles are parsed and generated. Ambiguous money,
conditional requirements, signature encodings and business status meanings need
an explicit profile/overlay; critical ambiguity is not guessed.

**What does the mock prove?** [PROJECT POLICY] It proves local wire shape,
authentication/error handling, adapter state behavior and callback integration
against the configured contract. It does not prove provider settlement or
sandbox/production acceptance.

**Where are idempotency and PCI boundaries?** [PROJECT POLICY] Default state is
in-memory, so there is no cross-process exactly-once promise. The showcase uses
synthetic SBP data, stores no real PAN/CVV and makes no PCI DSS claim. A host must
supply durable state, exact raw callback bytes/headers, secrets and operational
reconciliation.

## Handoff

Role 05 may link this static presenter pack but must not present it as a hosted
Ruby backend. A later acceptance role can run `examples/showcase/run NEW_DIR`,
archive that directory, record tool versions and hash the archive. The current
interface is the CLI/runtime at the tested Git SHA written to `tested-sha.txt`;
no `RELEASE_CONTRACT` was received.
