# Paygen

Paygen turns OpenAPI 3.0/3.1 contracts and explicit payout profiles into Ruby
adapters, integration guides and test examples. A local simulator exercises the
generated adapter, including retries, status transitions and callbacks.

Start with the [seven-minute demo](demo.md). It shows a complete workflow:
configure an integration, generate it, verify its behavior, export documentation
and run requests through Bruno or curl.

## Run an example

Requires Ruby 3.3 or later. Run from the repository root; `tmp/novapay` must be a
new directory.

```bash
gem install bundler -v 4.0.20
src/run setup
src/run cli init fixtures/novapay/openapi.yaml --output tmp/novapay
src/run cli generate tmp/novapay
src/run cli verify tmp/novapay --seed 42
```

The generated directory contains the adapter, `INTEGRATION.md`, fixtures and the
effective contract. The verifier should report `"success": true` and
`"failed": 0`.

## Find what you need

| Task | Guide |
| --- | --- |
| Present a working integration | [Seven-minute demo](demo.md) |
| Look up commands and output files | [CLI reference](cli.md) |
| Configure an unfamiliar payment API | [Native API onboarding](native-onboarding.md) |
| Compare provider evidence and download generated samples | [Provider catalog](provider-catalog.md) |
| Test the adapter over HTTP | [Bruno demo](bruno-demo.md) |
| Explore Russian payment APIs | [Russian bank examples](ru-bank-examples.md) |
| Understand the generator and runtime | [Architecture](architecture.md) |
| Check supported features and limitations | [Scope](scope.md) |
| Run tests, build containers or publish the manual | [Development](development.md) |

The manual describes Paygen. Each generated integration also has its own portable
Markdown or HTML guide, effective OpenAPI and examples. These can be delivered
with the adapter without publishing a website.

GitHub Pages serves this static manual and synthetic downloads only. It cannot
run the Ruby adapter, simulator, or demo backend. Run those locally as described
in the demo, without real credentials or payment-card data.
