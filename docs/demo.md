# Five-minute demo

Run commands from the repository root with Ruby and Bundler installed.

```bash
bundle install
bundle exec bin/paygen inspect fixtures/novapay/openapi.yaml
bundle exec bin/paygen init fixtures/novapay/openapi.yaml --output tmp/demo
bundle exec bin/paygen generate tmp/demo
bundle exec bin/paygen diff tmp/demo --check
bundle exec bin/paygen explain tmp/demo amount
bundle exec bin/paygen architecture-check tmp/demo
bundle exec rspec
```

The supplied recipe selects API operations, maps data and statuses, and applies
contract corrections. For a new provider, edit integration.yml until all semantic
blockers are resolved. `generate --draft` writes diagnostics without an executable
service when required semantics are missing.

The generated directory contains the Ruby service, INTEGRATION.md, fixtures.json,
config.json, provenance.json and diagnostics.json. Edit profiles or overlays to
change generated behavior. Keep custom Ruby hooks in extensions/.

Repeat with fixtures/paypal/openapi.yaml, fixtures/stripe/openapi.yaml and
fixtures/adyen/openapi.yaml. The latter packs are deliberately curated subsets;
their provenance files identify source versions and the extent of curation.

No command in this demo sends a live payout.
