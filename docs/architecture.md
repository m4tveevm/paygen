# Architecture and safety

OpenAPI source is pinned under source/. Ordered contract overlays are applied
before inference, vendor extensions, recipe defaults, the explicit profile and
ephemeral CLI overrides. Generated files are owned by Paygen; extensions are
owned by the application. The lock tracks input and output hashes.

The core has no provider branches. Profiles specify operations, mappings,
credentials references, amount units, statuses, retry and callback policy.
Network responses and user-owned hooks are outside the generator's trust boundary.

Inbound documents use safe YAML/JSON parsing, bounded reference resolution and
validated path handling. HTTPS ingestion rejects private addresses and pins DNS
resolution. Arbitrary Ruby in YAML is never evaluated.

Payout retries reuse stable idempotency identities. Timeouts may occur after a
provider commits a payout, so the outcome stays ambiguous until reconciled.
Unknown statuses and aggregate batch success cannot approve an individual payout.

Webhook verification operates on exact raw bytes. Replay and transition state
provided by the reference runtime is process-local; a production deployment must
integrate durable deduplication, idempotency and operation state with its backend.
The runtime exposes explicit hooks for that integration. Provider-specific
verification requiring a remote public-key API is an explicit hook contract.

Run the tests and completion audit before making production claims. A local
reference harness, offline mocks and generated code are not live-provider certification.
