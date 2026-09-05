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

Only canonical operation attributes are read from application objects by default.
Pass a Hash for arbitrary data, or explicitly add trusted backend attribute names
with `configure_paygen(allowed_attributes: [...])`. A YAML profile cannot extend
that list or invoke application methods. HTTP calls have a total 20-second deadline
in addition to connection/read timeouts. An explicit base_url overrides all roles;
otherwise operation-level server declarations take precedence.

## Standards boundaries

Overlay 1.1 supports ordered update/remove/copy, recursive merging, extends
identity and all RFC 9535 JSONPath selectors. Zero-match actions are warnings.
The pinned upstream JSONPath compliance suite is executed by RSpec.

Arazzo 1.1 documents are structurally validated with the official schema offline.
The payout executor supports HTTP/OpenAPI and nested workflows, runtime expressions,
parameters, input/output mappings, success/failure actions, retries including helper
steps, JSONPath and regular-expression criteria. The shipped four workflows replay
create/status calls using offline fixtures.

XPath, legacy JSONPath dialects, object/array parameter serialization and AsyncAPI
broker execution are explicitly unsupported by the executor. External network
schema references, dynamic references and cyclic schema expansion are denied.
Local references stay inside the source directory and are bundled safely.

Run the tests and completion audit before making production claims. A local
reference harness, offline mocks and generated code are not live-provider certification.

## Arazzo Ruby API

`Paygen::Core::Workflow.import` parses and validates a workflow; `export` returns
JSON or YAML; `run` executes a named workflow. Bind parsed source documents with
`sources: { source_name => document }`, or use the exact declared URL as the key.
Source descriptions are declarations: import, export and validation never fetch
their URLs. Load OpenAPI documents explicitly with `Paygen::Core::Input.load`.

Run this example from the repository root. Its transport replays the supplied
NovaPay responses and makes no network calls:

```sh
bundle exec ruby -Ilib <<'RUBY'
require 'paygen'
require 'json'

fixtures = JSON.parse(File.read('fixtures/novapay/fixtures.json'))
source = Paygen::Core::Input.load('fixtures/novapay/openapi.yaml')
responses = fixtures.fetch('workflow').fetch('response_names').map do |name|
  fixtures.fetch('responses').fetch(name)
end
transport = Object.new
transport.define_singleton_method(:request) do |method:, url:, headers:, body:|
  responses.shift || raise('Unexpected additional HTTP request')
end

workflow = Paygen::Core::Workflow.import(
  'fixtures/novapay/workflows/payout.arazzo.yaml',
  sources: { 'provider' => source }, transport: transport
)
exported = workflow.export(format: :json) # Use :yaml for YAML output.
raise 'Export changed the document' unless Paygen::Core::Input.parse(exported) == workflow.document
result = workflow.run('payout', inputs: fixtures.fetch('workflow').fetch('inputs'), seed: 42)
raise 'Replay failed' unless result.fetch('success') && responses.empty?
puts JSON.pretty_generate(result.fetch('outputs'))
RUBY
```

`validate!` also checks local workflow/step dependencies and action targets.
When a referenced source is supplied, it checks OpenAPI operation IDs/pointers
and external workflow/step identities. Without that source, external target
existence remains unresolved; successful validation alone does not establish
that a workflow can run. The checks do not automatically load or validate other
Arazzo documents recursively. Nested execution validates each supplied document
when it enters it. HTTP credentials belong in the injected transport.

The executor binds `$inputs`, `$steps`, `$workflows`, `$request`, `$response`,
`$statusCode`, `$url` and `$method` to execution state. `$sourceDescriptions`
exposes declaration metadata such as `.url`; qualified operation/workflow IDs
select explicitly supplied sources. HTTP `operationPath` currently requires
`{$sourceDescriptions.<name>.url}#/paths/<escaped-path>/<method>`.
Cross-document runtime expressions such as
`$sourceDescriptions.<name>.<workflowId>.outputs.<name>` or
`$sourceDescriptions.<name>.<workflowId>.steps.<stepId>` are not bound by this
executor. Pass nested workflow outputs through the invoking step's outputs.
`$self` exposes the document's literal value; base-URI normalization, source
fetching and asynchronous dependency scheduling are outside this executor.
