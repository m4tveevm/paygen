# Provider catalog and generated downloads

The labels below describe different evidence levels. Importing a contract is not
the same as generating an executable payout profile, and a local contract test is
not provider sandbox acceptance.

| Provider/example | Source kind | Executable profile | Signature verification | Independent local contract | Live sandbox |
| --- | --- | --- | --- | --- | --- |
| NovaPay | Authored case fixture | Focused SBP payout | HMAC-SHA256 over exact raw body | Local simulator and runtime tests | Not performed |
| Stripe | Curated focused contract | Focused payout | Stripe v1 callback | Local synthetic contract | Not performed |
| Adyen | Curated focused contract | Focused payout | HMAC profile | Local synthetic contract | Not performed |
| PayPal | Curated and native imports | Selected payout flow | Provider-specific verification delegated | Native HTTP expectations | Not performed |
| Paystack | Full native import | Selected transfer flow | Not claimed | Native HTTP expectations | Not performed |
| Raiffeisen | Full native import | Single-stage non-fiscal SBP | Configured request signing | Injected-transport expectations | Not performed |
| T-Bank | Full native import | No completed integration | Certificate signing unimplemented | Import/review only | Not performed |
| Tochka | Documentation review | No | Not implemented | Review only | Not performed |

## NovaPay synthetic artifacts

The documentation build creates these files by running the same Ruby
`Paygen::Generator` used by the CLI. They are not handwritten copies:

- <a href="downloads/novapay/INTEGRATION.md" download>INTEGRATION.md</a>
- <a href="downloads/novapay/fixtures.json" download>fixtures.json</a>
- <a href="downloads/novapay/config.json" download>effective configuration</a>
- <a href="downloads/novapay/diagnostics.json" download>diagnostics</a>
- <a href="downloads/novapay/provenance.json" download>provenance</a>
- <a href="downloads/novapay/manifest.json" download>source/profile/generator manifest</a>

All examples are synthetic. The build deliberately excludes service source,
uploaded specifications, environment files, state, credentials, and raw traces
from the Pages artifact. Generate a complete project locally when you need the
Ruby adapter or effective OpenAPI contract.

## Updating the catalog

After a provider source, profile, recipe, or generator change, run:

```bash
bundle exec rspec spec/generated_docs_spec.rb spec/native_packs_spec.rb
npm run docs:build
npm run docs:check
```

Review the evidence level above rather than increasing it automatically. The
generated download manifest records the exact input hashes and generator version;
`publication-manifest.json` at the site root records the source commit and hashes
every published file.
