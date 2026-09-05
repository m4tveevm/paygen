# Architecture

Paygen is a Ruby CLI with a provider-neutral parser, generator and runtime.
Provider-specific behavior lives in declarative profiles and optional Ruby
extensions. Ruby 3.3 or later is required; Node 22 is used only for the manual
build and the optional Bruno test runner.

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
`Input.graph(document, base_dir:)` processes an in-memory document;
`Input.resolve_fragment(document, value, base_dir:)` expands a selected contract.
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
configure_paygen(credentials:, transport:, base_url:, mode:, account:,
                token_provider:, state_store:, clock:, allow_local:,
                allowed_attributes:)
```

All arguments are optional. The injected transport
implements `request(method:, url:, headers:, body:)` and returns a hash containing
`status`, `headers` and `body`.

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
check after an ambiguous result. Callback signatures are verified against exact
raw bytes before state changes. Default replay and idempotency state is in memory;
the host application must supply durable, coordinated state and idempotent
backend mutations for deployment across workers or restarts.

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
key; import and validation never fetch source URLs. Validation checks local
dependencies and supplied external targets. Unprovided external sources remain
unresolved until execution.

The executor binds `$inputs`, `$steps`, `$workflows`, `$request`, `$response`,
`$statusCode`, `$url`, `$method` and literal `$self` values.
`$sourceDescriptions` exposes declaration metadata. HTTP `operationPath` uses
`{$sourceDescriptions.<name>.url}#/paths/<escaped-path>/<method>`.
Cross-document expressions accessing another workflow's internal steps are not
bound; pass nested results through the invoking step's outputs. Base-URI
normalization, automatic source fetching and asynchronous scheduling are outside
the executor's scope.
