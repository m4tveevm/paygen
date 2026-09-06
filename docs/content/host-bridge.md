# Embed the generated adapter in a host application

The repository contains an executable, explicitly declared local host contract in
`src/examples/host_bridge.rb`. It is not the organizer's unpublished production
`Provider::BaseService`. From the repository root, with the Ruby dependencies
installed, run:

```bash
src/run exec ruby src/examples/host_bridge.rb tmp/host-proof
```

Use a new output directory. The script generates and loads the Ruby subclass,
uses an application-like `Operation` object, checks literal HTTP payloads in an
independently authored fake transport, and observes changes in a fake backend.
It writes `report.json` with passed assertions, transport calls and backend effects.
There is no network connection, provider account or real payment.

## Logical actions and operation objects

The local object exposes `id`, a decimal-string `amount`, `currency`,
`payout_requisite` and `provider_operation_id`. The runtime reads its allowlisted
attributes. A profile cannot invoke arbitrary model methods; additional trusted
attributes must be allowed by application code.

`request_method` is the host's logical action, not an HTTP method. Canonical roles
remain `create`, `status`, `cancel` and `balance`. This example's profile adds:

```yaml
action_mapping:
  sbp: create
  check: status
```

Thus `service.create_request(operation, 'sbp')` follows the same amount checks,
request reservation and idempotency state as `create`. `check` selects the status
endpoint; `fetch_status(operation)` remains available. Unknown actions are refused
before HTTP. Aliases cannot form chains or remap canonical roles.

`BaseService.check_conditions(operation, request_method)` receives the original
logical action and may refuse before transport. Successful base prechecks do not
skip Paygen's own checks. These aliases belong to the example's declared host
contract; another backend can declare different names through its profile.

## Callbacks and backend mutation

The runtime's default callback behavior returns a result. A trusted Ruby extension
can opt in by overriding `paygen_callback_result(result, payload)` and calling
`paygen_backend_callback_result`. The example declares two backend methods:
`approve_operation(provider_id)` and `reject_operation(provider_id, error_code)`.
Translate these in your extension if your real backend uses another API.

Pass the exact raw HTTP bytes and headers to
`process_callback(payload, raw_body:, headers:)`. The example signs deliberately
formatted JSON using HMAC-SHA256 and hex encoding; reserializing the parsed object
is not an equivalent signing input. Failed signature checks make no backend change.

The proof covers progress and final states, duplicate callbacks, a rejected
backend update, an exception before backend mutation, retry of the same event,
and completed/failed outcomes. Paygen records a successful callback effect only
after the backend accepts it. An already applied terminal effect is not repeated.

Your host owns the durable transaction joining event deduplication and state
mutation, merchant isolation, concurrency and crash recovery. A crash between a
committed backend update and Paygen's record requires idempotent backend effects
or a shared transaction. The in-memory example proves local ordering, not
exactly-once processing across distributed workers.

## What travels with the adapter

A generated service contains its effective configuration and includes Paygen's
runtime. It is not a standalone single-file implementation. Use the installed gem
or `export --standalone`, which carries runtime source and dependency declarations.
Supply the host base class, credentials and durable state integration yourself.
Keep the generator project for later regeneration and documentation exports.

See [the dataset walkthrough](dataset-walkthrough.md) for portable HTML docs,
Bruno requests and the distinction between the adapter demo and provider mock.
