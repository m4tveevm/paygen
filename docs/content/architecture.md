# Architecture

Paygen is a Ruby CLI. Its parser, generator and runtime do not depend on a
particular payment provider. Provider-specific behavior belongs in declarative
profiles or, when needed, Ruby extensions. Paygen requires Ruby 3.3 or later.
You need Node 22 only to build this manual or run the optional Bruno tests.

## Contract processing

`source/openapi.json` pins the imported OpenAPI document. Paygen applies ordered
overlays before building an intermediate representation (IR). Semantic settings
are merged in this order, with later values taking precedence:

1. Inference from the effective OpenAPI document.
2. Its `x-paygen` extension.
3. Recipe defaults.
4. The project's `integration.yml` profile.
5. CLI overrides for the current generation.

`explain` reports the origin of a setting. Operation candidates include source
pointers and selection evidence. Amount units, settlement rules and signing
requirements need explicit configuration when the contract is ambiguous.
Unresolved blockers prevent service generation; draft mode emits diagnostics
and supporting files without an executable service.

| Component | Responsibility |
| --- | --- |
| `Core::Input` | Parse YAML/JSON, validate OpenAPI 3.0/3.1 and bundle local references |
| `Core::Overlay` | Apply ordered contract corrections |
| `Core::IR` | Inventory operations, combine profiles and diagnose unsupported semantics |
| `Project` | Manage source, profiles, extensions, hashes and generated-file ownership |
| `Generator` | Render the Ruby service, guide, fixtures, effective contract and provenance |
| `Runtime::Adapter` | Build requests, authenticate, map results and verify callbacks |
| `Runtime::Simulator` and `Runtime::Demo` | Exercise provider behavior and the generated adapter locally |

`Input.load(path_or_url, stdin: $stdin)` returns a validated reference graph.
`Input.graph(document, base_dir:, source_path:)` processes an in-memory document;
`Input.resolve_fragment(document, value, base_dir:, source_path:)` expands a selected contract.
Supply the optional `source_path` when the document came from a local file, so
references back to that file have the same identity as the root. Exported local
schema identities are portable; they do not authorize fetching new resources.
`Overlay.new(document).apply(overlay_hash)` returns the transformed document.

Input limits are 10 MiB, 100,000 nodes, 100 nesting levels, 1,000 expanded
references and 32 source files. Legal recursion in unused schemas can remain
in the graph. Cycles or dynamic references requiring expansion in a selected
operation produce an unsupported diagnostic. External network references are
denied; local references must stay within the source directory.

## Generated files and extensions

Generation writes `generated/` and updates `paygen.lock` with input and output
SHA-256 hashes. It checks generated Ruby syntax and refuses to overwrite manually
changed output. Edit the profile or `extensions/`, then regenerate. Extension
files are preserved and never executed during generation.

The generated service is a `Provider::<Name>Service < Provider::BaseService`
subclass that includes `Paygen::Runtime::Adapter`. Its `PAYGEN_CONFIG` constant
contains the effective profile, resolved endpoint contracts and source hash.
Endpoint records include method, path, parameters, request and response schemas,
security and servers.

Profiles use versioned YAML/JSON data with string keys. They select operations
and define request/parameter mappings, amount units, statuses, authentication,
errors, idempotency and callback policy. See
[provider configuration](native-onboarding.md) and the examples in `fixtures/`.

## Backend interface

The public runtime methods are:

```ruby
check_conditions(operation, request_method = 'create')
create_request(operation, request_method = 'create')
fetch_status(operation)
process_callback(payload, raw_body: nil, headers: {})
cancel(operation)
balance
```

`check_conditions` calls the superclass and preserves a failed result. Runtime
results are hashes with string keys, including `success`, canonical `status`,
provider identity or structured error details. The application supplies its
`Provider::BaseService`; repository tests use a compatibility harness.

Configure an instance with:

```ruby
configure_paygen(credentials:, transport:, base_url:, mode:, account:, state_namespace:,
                token_provider:, state_store:, clock:, allow_local:,
                allowed_attributes:)
```

All arguments are optional. If you supply an external `state_store`, you must also
set a stable `state_namespace` or `account` before execution. The injected
transport implements `request(method:, url:, headers:, body:)` and returns a hash
with `status`, `headers` and `body`.

An explicit `base_url` overrides every role. Otherwise operation-level servers
take precedence, with selection by mode. HTTP requests have a total 20-second
deadline in addition to connection/read timeouts. Only canonical attributes are
read from application objects; arbitrary data can be supplied as a Hash. Trusted
application code can extend the object allowlist through `allowed_attributes`.

Extensions can implement `paygen_validate`, `paygen_request`, `paygen_response`,
`paygen_status`, `paygen_classify_error` and `paygen_retry_decision`.
`paygen_verify_callback` supplies verification for provider-specific signatures
and rejects them by default. To apply verified callbacks to backend operations,
override `paygen_callback_result` and delegate to
`paygen_backend_callback_result`, which calls `approve_operation` or
`reject_operation`. Backend failure leaves the callback available for retry.

## Payment state and input safety

Money uses integer or decimal-string input and exact decimal conversion. Unknown
statuses cannot approve a payment. Batch completion requires a matching item
result before an individual payout is approved.

Stable identities bind retries to the original operation. Where duplicate
submission safety is unconfirmed, `reconcile_before_retry` requires a status
check after an ambiguous result. Provider-key retention is explicit and bounded;
expiry never clears the merchant operation reservation.

Polling, callbacks, creation and cancellation use the same lifecycle state.
Terminal results cannot regress to processing. Changes between terminal outcomes
require explicit `status_transitions`, except a status explicitly mapped to
`reversed`. Callback signatures are verified against exact raw bytes, while
logical replay identity uses the parsed event. Changed whitespace cannot trigger
the same backend callback effect twice. Runtime identifiers are preserved exactly;
redaction applies to diagnostic data, not functional identity fields.

Successful responses are validated against the declared response contract before
status interpretation. The simulator validates incoming requests before mutation.
Default replay and idempotency state is in memory;
the host application must supply durable, coordinated state and idempotent
backend mutations for deployment across workers or restarts.

State keys separate provider, mode and the explicitly configured merchant scope.
Use a stable scope across credential rotation, and distinct scopes for separate
accounts. Missing scope on an injected store returns `state_namespace_required`
before HTTP or callback effects. A recognized old reservation/lifecycle key
returns `state_migration_required`: stop old writers, reconcile ambiguous payments
and migrate reviewed state. Clearing the store or rotating the namespace is not a
safe migration. These guards do not replace the host's durable transaction design.

Cached and retained results preserve the same `BigDecimal` money type as the
first result, including when a store serializes its values as JSON. The private
state envelope is not the public result format. Distinct intermediate callback
events still reach the host hook even when both map to `in_progress`; repeated
terminal effects and actual duplicate deliveries are handled separately.

YAML/JSON parsing does not evaluate code. HTTPS ingestion rejects private
addresses and pins DNS resolution. Request headers that control transport framing
are denied, including changes from extensions. Runtime error output redacts
credentials. `Paygen::Error` exposes a `code`, `exit_code` and `details` hash;
diagnostics contain `code`, `severity`, `message` and `path`.

## Overlay and Arazzo support

Overlay 1.1 processing includes ordered update/remove/copy actions, recursive
merging, `extends` identity and RFC 9535 JSONPath selection. Zero-match actions
produce warnings. The test suite includes the pinned upstream JSONPath compliance
cases.

Arazzo 1.1 documents are validated against the bundled official schema. The
executor supports HTTP/OpenAPI and nested workflows, runtime expressions,
parameters, input/output mappings, success/failure actions, retries, JSONPath
and regular-expression criteria. XPath, legacy JSONPath dialects, object/array
parameter serialization and AsyncAPI broker execution are unsupported.

```ruby
source = Paygen::Core::Input.load('fixtures/novapay/openapi.yaml')
workflow = Paygen::Core::Workflow.import(
  'fixtures/novapay/workflows/payout.arazzo.yaml',
  sources: { 'provider' => source }, transport: transport
)
workflow.export(format: :json) # Also supports :yaml.
workflow.run('payout', inputs: inputs, seed: 42)
```

Supply `transport` and the workflow's declared `inputs`. The transport owns HTTP
authentication. `sources` accepts a declared source name or its exact URL as a
key; import and validation never fetch source URLs. Execution requires an explicit
transport and checks capabilities across the reachable workflow graph before its
first request. Unavailable sources, unsupported criteria and invalid dependencies
fail during this preflight. Forward step dependencies run in stable dependency
order; cyclic or unscheduled prerequisites are rejected.

Cross-workflow output references require an explicit workflow `dependsOn`.
References in descriptions are documentation, not executable dependencies.

A lost response or ambiguous server error after a write stops execution with
`ARAZZO_RECONCILIATION_REQUIRED`. Retry and goto actions cannot repeat that write,
including through a nested workflow. Bounded read retries and explicit 401/429
recovery remain supported. Provider reconciliation and durable payment state
belong to the application; the workflow executor does not infer safe write retries.

A per-run ledger also prevents returning to a completed write after a later read
fails. It records both the wire fingerprint and the source document/workflow/step
identity. Refreshing a prerequisite, changing the payload or invoking the same
nested workflow again does not permit a second payment from that write step.
Different payments in one run require distinct write steps; a new top-level run
starts a separate ledger.

For an operation that the application explicitly knows is repeatable,
such as token refresh, pass `repeatable_operations` to the Ruby constructor:
`[{ method: 'POST', url: 'https://provider.example/v1/refresh' }]`. Entries match
the exact HTTP method and absolute URL. This trusted application option cannot
be enabled by an imported Arazzo extension.

The executor binds `$inputs`, `$steps`, `$workflows`, `$request`, `$response`,
`$statusCode`, `$url`, `$method` and literal `$self` values.
`$sourceDescriptions` exposes declaration metadata. HTTP `operationPath` uses
`{$sourceDescriptions.<name>.url}#/paths/<escaped-path>/<method>`.
Cross-document expressions accessing another workflow's internal steps are not
bound; pass nested results through the invoking step's outputs. Base-URI
normalization, automatic source fetching and asynchronous scheduling are outside
the executor's scope.
