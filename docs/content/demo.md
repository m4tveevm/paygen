# Base run: generate and run a payout adapter

Start with NovaPay, a fictional payment API included in the repository. In this
run, you'll turn its OpenAPI contract into a Ruby adapter, start a local demo
application and send a payout through the generated code.

The request follows this path:

```text
Browser panel or curl → demo application → generated Ruby adapter → NovaPay simulator
```

The demo application supplies the backend hooks and operation storage that the
adapter needs. The adapter converts your application's payment fields into
NovaPay requests and maps the responses back to application statuses. The
simulator acts as the payment provider. Everything runs locally with synthetic
data; restarting the demo clears its operations.

## Set up the project

Install Bash, curl and Ruby using [toolchain setup](development.md#toolchain).
The checkout pins Ruby 4.0.6 and supports Ruby 3.3 or later. From the repository
root:

```bash
gem install bundler -v 4.0.20
src/run setup
src/run cli init fixtures/novapay/openapi.yaml --output tmp/base-run
src/run cli configure tmp/base-run
```

Use a new output directory for `init`. If you're returning to an existing
`tmp/base-run`, skip that command and continue with the saved project.

`init` creates the integration project. `configure` reports which payment
operations and rules it can use. NovaPay has a bundled profile, so the report
returns `"ready": true`.

The two inputs have different jobs:

| Input | What it defines |
| --- | --- |
| `fixtures/novapay/openapi.yaml` | NovaPay's endpoints, request fields and response schemas |
| `tmp/base-run/integration.yml` | How the application uses that API: payout creation, amount conversion, status mapping and callback verification |

For example, the profile selects `createPayout` for creation, converts rubles to
integer kopecks and maps NovaPay's `completed` status to `approved`. For a new
provider, unresolved choices appear in the configuration report. The
[onboarding guide](native-onboarding.md) explains how to fill them in.

## Generate the adapter

```bash
src/run cli generate tmp/base-run
src/run cli verify tmp/base-run --seed 42
```

The generated files are in `tmp/base-run/generated/`:

- `novapay_service.rb` is the Ruby adapter that the demo will load.
- `INTEGRATION.md` describes its configuration and the hooks your backend supplies.
- `effective-openapi.json` is the contract with the project's overlays applied.
- `fixtures.json` contains examples for the integration.

`verify` exercises the adapter against the simulator, including retries,
timeouts and callback checks. A passing run reports `"success": true` and
`"failed": 0`. The seed makes the simulation repeatable.

## Start the demo application

```bash
src/run cli demo tmp/base-run --port 9293
```

Leave this terminal running and open [localhost:9293](http://127.0.0.1:9293/).
The panel loads the generated adapter's details and an editable sample operation
for NovaPay. You can create a payout, repeat the request, fetch its status and
inspect the simulator's records from this page.

`demo` connects the application operations to the generated adapter and simulator.
The separate `serve` command starts a provider-shaped mock API for an external
client; it isn't needed for this run.

## Send a payout

For a reproducible sequence, use the following commands in a second terminal.
Start with a fresh demo process and run them in order. The browser panel calls
the same application API; using its buttons also changes the demo's state.

```bash
curl --noproxy '*' -sS http://127.0.0.1:9293/operations \
  -H 'Content-Type: application/json' \
  -d '{"id":"base-run-1","amount":"1500.00","currency":"RUB","payout_requisite":{"sbp":{"phone":"79990000001","bank_code":"000000000"}}}'
```

This is an application operation: its ID, amount, currency and recipient details.
The adapter builds the NovaPay request, including the conversion from `1500.00`
rubles to `150000` kopecks. The response contains a `provider_id` and
`status: in_progress`: the provider has accepted the payout, and it is still
processing.

Repeat the same operation through the retry endpoint:

```bash
curl --noproxy '*' -sS http://127.0.0.1:9293/operations/base-run-1/retry \
  -H 'Content-Type: application/json' -d '{}'
```

The adapter returns the same `provider_id`. It already has a successful creation
response for this operation, so it reuses that result.

Now fetch the status twice:

```bash
curl --noproxy '*' -sS http://127.0.0.1:9293/operations/base-run-1
curl --noproxy '*' -sS http://127.0.0.1:9293/operations/base-run-1
```

The default simulator scenario advances from `in_progress` on the first poll to
`approved` on the second. The adapter translates the provider's status into the
application's status on each response.

Inspect the provider side:

```bash
curl --noproxy '*' -sS http://127.0.0.1:9293/evidence
```

`/evidence` exposes the simulator's records and the demo's backend events.
`created_count: 1` means the sequence created one provider payout, including
after the retry.

## Keep the integration files

You can export a browsable guide and a Bruno collection from the same project:

```bash
src/run cli docs tmp/base-run --format html --output tmp/base-run-docs
src/run cli collection tmp/base-run --format bruno --output tmp/base-run-bruno
```

Use new output directories for these exports. Open
`tmp/base-run-docs/index.html` to read the generated integration guide. The
[Bruno guide](bruno-demo.md) explains how to run the collection against the demo,
including cancellation and callbacks.

To embed the adapter in your own Ruby application, follow
[the standalone export instructions](dataset-walkthrough.md#export-the-adapter-and-its-documentation).
Your application supplies the backend hooks, credentials, transport and durable
operation state described in the generated `INTEGRATION.md`.

Stop the demo with Ctrl-C when you're done. For another provider, continue with
[the dataset walkthrough](dataset-walkthrough.md) or
[Russian bank examples](ru-bank-examples.md). For automated checks across
providers and failure scenarios, see [testing](testing.md).
