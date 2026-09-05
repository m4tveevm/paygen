# Paygen implementation contracts

Ruby >= 3.3. Public module: `Paygen`. Gem runtime uses dry-cli, json_schemer,
janeway-jsonpath, rack/puma, prop_check, listen and diff-lcs. Never use eval on
input. All input keys are strings. Core contains no provider names.

## Component ownership and interfaces

- Root: `lib/paygen.rb`, `lib/paygen/core/ir.rb`, `lib/paygen/project.rb`,
  `lib/paygen/generator.rb`, `lib/paygen/cli.rb`, bin, scaffold, CI, docs.
- Parsing agent: `lib/paygen/core/{input,overlay,workflow}.rb` and matching specs.
  `Input.load(path_or_url, stdin: $stdin)` => validated OpenAPI Hash.
  `Input.parse(text)` => safe data Hash. `Input.resolve(document, base_dir:)`
  => resolved document; deny unsafe/cyclic/excessive refs. Errors use below.
  `Overlay.new(document).apply(overlay_hash)` => transformed Hash;
  `#diagnostics` => diagnostic Hashes. No silent unsupported selectors.
  `Workflow.new(document, sources: {}, transport: nil)`; `#validate!`,
  `#run(workflow_id, inputs: {}, seed: 0)` => result Hash.
- Runtime agent: `lib/paygen/runtime/*`, `spec/runtime*`, reference harness.
  `Paygen::Runtime::Adapter` is a mixin included by generated
  `Provider::<Name>Service < Provider::BaseService`.
  Configuration supplied by `self.class::PAYGEN_CONFIG` (JSON-shaped Hash).
  APIs: check_conditions(operation, request_method='create'),
  create_request(operation, request_method='create'), fetch_status(operation),
  process_callback(payload, raw_body: nil, headers: {}), cancel(operation),
  balance. HTTP transport injectable: configure_paygen(credentials: {},
  transport: nil, base_url: nil, mode: 'sandbox', account: nil).
  Transport request(method:, url:, headers:, body:) => {status:, headers:, body:}.
- Fixtures agent: `fixtures/*`, `recipes/*`, `spec/packs*`, provenance only.

## Shared models

`Paygen::Error < StandardError`: `code` string, `exit_code` integer,
`details` Hash. `Error.new(message, code: 'PROJECT_ERROR', exit_code: 2, details: {})`.

Diagnostic Hash: `code`, `severity` ('warning'/'blocker'), `message`, `path`.

Integration profile version 1:

```yaml
version: 1
provider: example
class_name: ExampleService
mode: sandbox
operations:
  create: createPayout
  status: getPayoutStatus
  cancel: cancelPayout
  balance: getBalance
  callback: payoutWebhook
amount:
  scale: 100
  minimum: 100000
  currencies: [RUB]
request_mapping:
  amount: {from: amount, transform: minor_units}
  currency: {from: currency}
  external_id: {from: id}
  recipient.type: {value: sbp}
  recipient.phone: {from: payout_requisite.sbp.phone}
  recipient.bank_code: {from: payout_requisite.sbp.bank_code}
status_mapping: {pending: in_progress, completed: approved, failed: rejected}
response: {id: id, status: status, error: error.code}
idempotency: {header: Idempotency-Key}
auth: {type: apiKey, in: header, name: X-API-Key, credential: api_key}
callback:
  signature: {algorithm: hmac-sha256, header: X-Signature, encoding: hex, credential: callback_secret}
  id: payout_id
  status: status
  event: event
  events: {payout.completed: completed}
errors:
  '429': {code: rate_limit, action: retry}
```

Generated runtime config merges the profile with `endpoints`:
role => {method, path, request_schema, responses, parameters, security, servers};
`servers` accepts URL strings or OpenAPI server objects. Operation servers take
precedence, with mode selection; an explicit runtime base_url overrides all roles.
`source_hash` is SHA256.
Never hardcode any provider in runtime or core. Profile extension fields must be
documented and tested. Runtime failures are structured results, secrets redacted.

## Verification

Only executed checks are evidence. No skipped tests, fake success, or claiming
full standards compatibility for an incomplete implementation. Full goal status
stays CONTINUE until the complete documented gate passes.
