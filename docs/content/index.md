# Paygen

Paygen takes an OpenAPI 3.0 or 3.1 contract and a payout profile, then generates
a Ruby adapter, an integration guide and test examples. Its local simulator can
exercise the adapter's retries, status changes and callbacks without contacting
a payment provider.

If this is your first visit, start with the [base run](demo.md). You will
configure and generate an integration, verify it, export its documentation and
send requests with Bruno or curl.

## Run an example

First, clone [the repository](https://github.com/m4tveevm/paygen). Select Ruby
4.0.6 as described in [toolchain setup](development.md#toolchain); Paygen supports
Ruby 3.3 and later. Run these commands in Bash from the checkout root. The path
`tmp/novapay` must not exist yet. The commands run on your computer, not on this
website.

```bash
gem install bundler -v 4.0.20
src/run setup
src/run cli doctor
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
| Generate and run your first adapter | [Base run](demo.md) |
| Look up commands and output files | [CLI reference](cli.md) |
| Configure an unfamiliar payment API | [Native API onboarding](native-onboarding.md) |
| Compare provider evidence and download generated samples | [Provider catalog](provider-catalog.md) |
| Test the adapter over HTTP | [Bruno demo](bruno-demo.md) |
| Explore Russian payment APIs | [Russian bank examples](ru-bank-examples.md) |
| Understand the generator and runtime | [Architecture](architecture.md) |
| Check supported features and limitations | [Scope](scope.md) |
| Run tests, build containers or publish the manual | [Development](development.md) |

This English-language manual covers Paygen itself. Given the same pinned source,
profile, overlays, recipe and toolchain, Paygen produces the same output; see
[reproducible output](cli.md#reproducible-output). When payment details are
missing, Paygen reports them instead of guessing. Every generated integration
also includes a portable Markdown or HTML guide, its effective OpenAPI contract
and examples, so you can ship the documentation with the adapter.

GitHub Pages hosts only this static manual and its synthetic downloads. To use
the Ruby adapter, simulator or demo backend, run them locally as described in the
demo. Do not use real credentials or payment card data.
