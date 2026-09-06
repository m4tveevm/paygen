Источники: `provider_api.yaml` (organizer-supplied fictional NovaPay original, SHA-256 `415f50ee36fb331dfab49ceed0e8ed3b0ebe16053d7e00dbabd32282f4396551`); https://github.com/m4tveevm/paygen (authored local host contract).

# Explicit host bridge

Run from the repository root with a new output directory:

```bash
src/run exec ruby src/examples/host_bridge.rb tmp/host-proof
```

The script generates a NovaPay subclass, loads it against a small declared
`BaseService`, passes a Ruby `Operation` object, and asserts independent wire
expectations. It creates, checks status, authenticates raw callback bytes, and
observes the fake backend's `approved` and `rejected` state changes.
`report.json` records every passed assertion and transport/backend effect.
No request reaches a real provider or a network socket.

The example explicitly configures `action_mapping: {sbp: create, check: status}`.
These are this host's logical action names, not HTTP verbs and not a universal
host vocabulary. Alias normalization happens before monetary prechecks and
idempotency reservation. The base precheck receives the original logical action
and may refuse it before HTTP. Unknown actions fail explicitly. Canonical roles
cannot be remapped and aliases cannot point to aliases.

`CallbackBridge` opts into `paygen_backend_callback_result`; return-only callback
handling remains the runtime default. The local seam expects
`approve_operation(provider_id)` and `reject_operation(provider_id, error_code)`.
It does not claim to be the organizer's unpublished production BaseService API.
Use a trusted extension to translate these calls to your application's API.

The example authenticates HMAC-SHA256 over the exact raw body with hex encoding.
Duplicate successful effects are suppressed. A backend failure result or exception
before mutation leaves the callback unconsumed and permits retry. Progress and
late events do not regress the terminal backend state.

The fake's in-memory store demonstrates ordering within one process. A production
host owns the atomic transaction joining durable event deduplication and backend
mutation, merchant scope, crash recovery and concurrent workers. A crash after the
backend commits but before Paygen records its result needs idempotent host effects
or a shared transaction; this example does not establish distributed exactly-once.
Generated Ruby includes configuration and a runtime include, not every dependency
in a single file. Keep the Paygen gem or use `export --standalone` with its runtime
and declared dependencies, then supply your host class and credentials.
