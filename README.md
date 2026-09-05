# Paygen

Paygen generates Ruby payout integrations from OpenAPI 3.0/3.1 and a configuration
profile. It produces an adapter, integration documentation and test examples,
then checks the adapter against a local provider simulator.

The profile defines the decisions an API schema cannot reliably supply: which
operation sends money, how amounts and recipients are represented, which statuses
confirm settlement, and how retries and callbacks work.

## Quickstart

Install Ruby 3.3 or later, then run from a fresh checkout:

```bash
git clone https://github.com/m4tveevm/paygen.git
cd paygen
gem install bundler -v 4.0.20
bundle install
bundle exec bin/paygen init fixtures/novapay/openapi.yaml --output tmp/novapay
bundle exec bin/paygen generate tmp/novapay
bundle exec bin/paygen diff tmp/novapay --check
bundle exec bin/paygen verify tmp/novapay --seed 42
```

The bundled NovaPay example includes its configuration and contract corrections.
`diff` reports `"changed": false`; `verify` reports `"success": true` and
`"failed": 0`. Its checks cover creation, status polling, repeated requests,
timeouts, rate limits, cancellation and signed callbacks.

`init` requires a new output directory. Reuse an existing project by starting with
`generate`, or choose another directory for a new example.

## Use the generated integration

| Output in `tmp/novapay/generated/` | Purpose |
| --- | --- |
| `novapay_service.rb` | Adapter subclassing `Provider::BaseService` |
| `INTEGRATION.md` | Endpoints, setup, mappings and request examples |
| `fixtures.json` | Request, response and callback examples |
| `effective-openapi.json` | Contract after applying corrections |
| `config.json`, `diagnostics.json`, `provenance.json` | Effective settings, validation results and the source of each setting |

Export a portable HTML guide and a Bruno collection, then start the local demo:

```bash
bundle exec bin/paygen docs tmp/novapay --format html --output tmp/novapay-docs
bundle exec bin/paygen collection tmp/novapay --format bruno --output tmp/novapay-bruno
bundle exec bin/paygen demo tmp/novapay --port 9293
```

Open `tmp/novapay-docs/index.html` in a browser. In Bruno, open
`tmp/novapay-bruno`, select the `local` environment and run the collection in
order. The demo invokes the generated adapter, checks its requests in the provider
simulator, and processes signed callbacks. It listens on `127.0.0.1` and uses
synthetic credentials and payment data.

HTML and collection generation require only Ruby. Node is needed for the optional
Bruno CLI and the Paygen manual's site build. Export directories must be new.

## Configure another API

```bash
bundle exec bin/paygen init provider.yaml --output tmp/provider
bundle exec bin/paygen configure tmp/provider
bundle exec bin/paygen configure tmp/provider --answers profile.yml
bundle exec bin/paygen generate tmp/provider
bundle exec bin/paygen verify tmp/provider --seed 42
```

`configure` lists candidate operations, source locations and unanswered questions.
Resolve these in `integration.yml` or apply a profile before generating executable
code. Change the source, profile or overlays to regenerate; put custom Ruby hooks
in `extensions/`. Paygen detects manual changes to generated files.

Examples include NovaPay, Stripe, Adyen, PayPal, Paystack and Raiffeisen SBP
payouts. The [example catalog](fixtures/README.md) distinguishes full source
contracts from focused fixtures. T-Bank and Tochka illustrate signing and workflow
requirements that need additional integration work.

## Documentation

- [Seven-minute demo](docs/demo.md): commands and expected results for a walkthrough.
- [CLI reference](docs/cli.md): configuration, generation and exports.
- [Native API onboarding](docs/native-onboarding.md): profiles and the API corpus.
- [Bruno demo](docs/bruno-demo.md) and [Russian bank examples](docs/ru-bank-examples.md).
- [Architecture](docs/architecture.md), [supported scope](docs/scope.md) and [development](docs/development.md).

The prototype demonstrates generation and local adapter behavior. Connecting a
real application also requires its `Provider::BaseService` hooks, durable state
storage and provider sandbox verification. Generated integration guides can be
distributed with the adapter; GitHub Pages is an optional host for the Paygen manual.

## Development

```bash
bundle exec rspec
script/smoke
```

See the [development guide](docs/development.md) for the complete checks,
documentation build and containers.

Paygen is licensed under [MIT](LICENSE). Third-party API snapshots keep their
source and license information alongside the fixtures.
