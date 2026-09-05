# Paygen

Paygen generates Ruby payout integrations from OpenAPI 3.0/3.1 contracts and
explicit semantic profiles. It generates a Provider::BaseService subclass,
an integration guide, fixtures and fact provenance. No AI model is used at runtime.

Start with the [five-minute demo](demo.md), then review
[architecture and safety](architecture.md).

Requirements: Ruby 3.3 or later and Bundler. The reference container uses Ruby
4.0.6. Documentation uses Node 22 and pinned Diplodoc CLI.

```bash
bundle install
bundle exec bin/paygen doctor
bundle exec bin/paygen init fixtures/novapay/openapi.yaml --output tmp/demo
bundle exec bin/paygen generate tmp/demo
```

Inspect generated output before connecting to your backend. The included
reference harness is a test seam for the unpublished Provider::BaseService API.
