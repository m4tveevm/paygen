# Provider catalog and generated downloads

The labels below describe different evidence levels. Importing a contract is not
the same as generating an executable payout profile, and a local contract test is
not provider sandbox acceptance.

| Provider/example | Source kind | Executable profile | Signature verification | Independent local contract | Live sandbox |
| --- | --- | --- | --- | --- | --- |
| NovaPay | Authored case fixture | SBP and card payout mappings | HMAC-SHA256 over exact raw body | Local simulator, runtime and mapping tests | Not performed |
| Stripe | Curated focused contract | Focused payout | Stripe v1 callback | Local synthetic contract | Not performed |
| Adyen | Curated focused contract | Focused payout | HMAC profile | Local synthetic contract | Not performed |
| PayPal | Curated and native imports | Selected payout flow | Provider-specific verification delegated | Native HTTP expectations | Not performed |
| Paystack | Full native import | Selected transfer flow | Not claimed | Native HTTP expectations | Not performed |
| Raiffeisen | Full native import | Single-stage non-fiscal SBP | Not claimed; request authentication is bearer | Injected-transport expectations | Not performed |
| T-Bank | Full native import | No completed integration | Certificate signing unimplemented | Import/review only | Not performed |
| Tochka | Documentation review | No | Not implemented | Review only | Not performed |

## NovaPay synthetic artifacts

The documentation build creates these files by running the same Ruby
`Paygen::Generator` used by the CLI, then redacts long payment identifiers for
publication. They are not handwritten copies:

- <a href="downloads/novapay/INTEGRATION.md" download>INTEGRATION.md</a>
- <a href="downloads/novapay/fixtures.json" download>fixtures.json</a>
- <a href="downloads/novapay/config.json" download>effective configuration</a>
- <a href="downloads/novapay/diagnostics.json" download>diagnostics</a>
- <a href="downloads/novapay/provenance.json" download>provenance</a>
- <a href="downloads/novapay/manifest.json" download>source/profile/generator manifest</a>

All examples are synthetic. Fixtures include the deliberately public test secret
`paygen-public-fixture-secret` to reproduce callback signatures. Never use it as
an application credential. The configuration contains credential **names**, not
your runtime credentials, and may include contract schemas and synthetic examples.

The build publishes only the five generated files listed above and their manifest;
it excludes service source, the full uploaded specification, environment files,
state and raw traces. The artifact gate rejects unexpected files, symbolic/hard
links, obvious private-key/token patterns and unmasked long payment identifiers
in downloads. These checks supplement human review; they are not a proof that
arbitrary uploaded data is safe to publish. Downloads are built from the pinned
NovaPay case fixture, never from user uploads. Generate a complete project locally
when you need the Ruby adapter or effective OpenAPI contract.

Published samples may contain `[REDACTED]`, including the synthetic card number
from the original case. They are documentation, not executable wire fixtures.
Generate locally to obtain unchanged synthetic test inputs. The download manifest
records original generated hashes and published hashes separately, with the
publication transform identifier; the runtime and source contract are not changed.

## Updating the catalog

After [Ruby and Node dependency setup](development.md#toolchain), run from the
repository root whenever a provider source, profile, recipe, or generator changes:

```bash
src/run test src/spec/generated_docs_spec.rb src/spec/native_packs_spec.rb
pnpm --dir docs run docs:build
pnpm --dir docs run docs:check
```

Review the evidence level above rather than increasing it automatically. The
generated download manifest records the source fixture hash, profile hash, all
effective generator-input hashes (including recipe/overlays) and generator version;
`publication-manifest.json` at the site root records the source commit and hashes
every published file.
