# Seven-minute demo

For an automated, repeatable proof, run `examples/showcase/run NEW_EMPTY_DIR`.
The [showcase pack](testing.md#reproducible-showcase-and-deliberate-failure) executes NovaPay, Stripe,
PayPal and Adyen adapters through loopback HTTP, checks independent invalid wire
requests, demonstrates profile + Overlay adaptation, and compares a disposable
failing mutant with the unchanged adapter on the exact same shrunk trace.
The panel loads editable provider-specific synthetic examples from `/sample`;
it does not hardcode a NovaPay request for every provider.

This walkthrough generates a NovaPay adapter, checks repeatability and failure
handling, then makes HTTP requests through it. All requests stay on the local
machine and use synthetic payment data.

## Prepare before the walkthrough

Install Bash, curl and Ruby (the checkout pins 4.0.6; Ruby 3.3 and later are
supported). Select Ruby using [toolchain setup](development.md#toolchain), then
run from the repository root:

```bash
gem install bundler -v 4.0.20
src/run setup
```

Use two terminals in the repository root. The output directories below must be
new. For another run, keep the generated project and skip `init` and exports,
or use new directory names. Restarting the demo clears its in-memory operations.

## 1. Show the input and configuration — one minute

```bash
src/run cli init fixtures/novapay/openapi.yaml --output tmp/presentation
src/run cli configure tmp/presentation
```

Open `tmp/presentation/integration.yml`. The bundled profile maps
`createPayout` to creation, converts rubles to integer kopecks, and maps
`completed` to `approved`. The configuration report has `"ready": true`.

For an unfamiliar API, the same report lists unresolved questions. A method name
alone cannot establish whether money was sent or whether a retry is safe.

## 2. Generate and verify — one minute

```bash
src/run cli generate tmp/presentation
src/run cli generate tmp/presentation
src/run cli diff tmp/presentation --check
src/run cli verify tmp/presentation --seed 42 > tmp/presentation-checks.json
```

The second generation produces the same files; `diff` returns
`{"changed": false, "files": []}`. Open `tmp/presentation-checks.json`: expect
`"success": true` and `"failed": 0`. The report includes timeout after creation,
rate limiting, repeated requests, unknown statuses and invalid callback signatures.

Open `tmp/presentation/generated/novapay_service.rb` and `INTEGRATION.md` to show
the adapter and its matching integration guide. Both come from the same profile.

## 3. Export deliverables and start the application — one minute

```bash
src/run cli docs tmp/presentation --format html --output tmp/presentation-docs
src/run cli collection tmp/presentation --format bruno --output tmp/presentation-bruno
src/run cli demo tmp/presentation --port 9293
```

Open `tmp/presentation-docs/index.html` in a browser. The directory also contains
the effective OpenAPI and fixtures, so the guide can travel with the adapter.

Leave the server running in the first terminal. Wait for
`Paygen adapter demo listening on http://127.0.0.1:9293` before continuing.

## 4. Create, repeat and settle a payout — two minutes

In the second terminal:

```bash
curl --noproxy '*' -sS http://127.0.0.1:9293/health

curl --noproxy '*' -sS http://127.0.0.1:9293/operations \
  -H 'Content-Type: application/json' \
  -d '{"id":"presentation-1","amount":"1500.00","currency":"RUB","payout_requisite":{"sbp":{"phone":"79990000001","bank_code":"000000000"}}}'

curl --noproxy '*' -sS http://127.0.0.1:9293/operations/presentation-1/retry \
  -H 'Content-Type: application/json' -d '{}'

curl --noproxy '*' -sS http://127.0.0.1:9293/operations/presentation-1
curl --noproxy '*' -sS http://127.0.0.1:9293/operations/presentation-1
curl --noproxy '*' -sS http://127.0.0.1:9293/evidence
```

| Request | Expected result |
| --- | --- |
| Create | `success: true`, `status: in_progress`, a `provider_id`; provider amount is `150000` kopecks |
| Retry | The same `provider_id` |
| First status poll | `status: in_progress` |
| Second status poll | `status: approved` |
| Evidence | `created_count: 1` despite the repeated request |

The demo receives an application operation, invokes the generated adapter, and
passes the adapter's provider request to the simulator. `/evidence` shows which
provider operations were actually created.

## 5. Show a rejected request — one minute

```bash
curl --noproxy '*' -sS http://127.0.0.1:9293/checks/invalid-auth \
  -H 'Content-Type: application/json' -d '{}'
curl --noproxy '*' -sS http://127.0.0.1:9293/evidence
```

The application returns HTTP 422 with `success: false`,
`error.code: unauthorized` and the provider's `error.http_status: 401`.
`created_count` remains `1`.

For the callback sequence, open `tmp/presentation-bruno` in Bruno, select `local`
and run all requests in order. It checks creation, cancellation, repeated
requests, valid and invalid signatures, and duplicate callback delivery.
The collection uses fresh IDs, so it can run after the curl example.
See [Bruno demo](bruno-demo.md) for the optional CLI runner.

## Optional: timeout after creation

Stop the first server with Ctrl-C, then start a fresh scenario:

```bash
src/run cli demo tmp/presentation --scenario timeout_after_commit --port 9293
```

Repeat the create, retry and evidence requests from step 4. Creation returns
`transport_timeout` with `ambiguous: true`: the provider committed the operation
before the connection failed. Retrying returns `reconciliation_required` and
sends no second create; `created_count` stays `1`. The NovaPay contract does not
specify key retention, so the profile cannot promise a safe provider retry.
Resolve the original operation through the provider's lookup or reconciliation
process before recording its outcome.

Stop this server before running the Bruno success collection again.

## Optional: a Russian bank contract

```bash
src/run cli init fixtures/raiffeisen_payouts/upstream/openapi.json \
  --output tmp/presentation-raiffeisen
src/run cli generate tmp/presentation-raiffeisen
src/run cli verify tmp/presentation-raiffeisen --seed 42
src/run cli docs tmp/presentation-raiffeisen --format html \
  --output tmp/presentation-raiffeisen-docs
```

This profile uses the full Raiffeisen contract for single-stage SBP payouts.
Its amounts are exact JSON numbers in rubles. An ambiguous creation requires
status reconciliation before another payout can be submitted. The
[Russian bank guide](ru-bank-examples.md) explains this profile and the additional
signing and workflow requirements in T-Bank and Tochka APIs.

The walkthrough demonstrates a generated integration against its configured
contract. A real deployment additionally needs backend hooks, durable operation
state and bank sandbox verification; see [supported scope](scope.md).
