# Paygen

Generate deterministic Ruby payout integrations from OpenAPI 3.0/3.1 and explicit
semantic profiles. No LLM or hosted AI is used by the shipped application.

```bash
bundle install
bundle exec bin/paygen init fixtures/novapay/openapi.yaml --output tmp/novapay
bundle exec bin/paygen generate tmp/novapay
bundle exec bin/paygen diff tmp/novapay --check
bundle exec bin/paygen verify tmp/novapay --seed 42
```

Requires Ruby >=3.3. Reference image: `ruby:4.0.6-slim`.

Outputs: a `Provider::BaseService` subclass, `INTEGRATION.md`, `fixtures.json`,
effective configuration, diagnostics and provenance. The real backend base class
is not published with the case; `spec/support/provider_harness.rb` is the
reference seam, and runtime outcomes are structured hashes.

## Project workflow

```text
source/          pinned OpenAPI
overlays/        ordered Overlay 1.1 corrections
integration.yml explicit semantic configuration
workflows/       Arazzo descriptions
recipes/         selected default rules
extensions/      trusted user-owned Ruby hooks
scenarios/       offline payout scenarios
generated/       Paygen-owned files
paygen.lock      input and generated-file hashes
```

Input contracts are untrusted data. YAML cannot execute Ruby. Safe refs, bounded
parsing, HTTPS DNS pinning and project path checks protect ingestion. Generated
edits cause a drift error; extension files are preserved. `generate --draft`
produces diagnostics when semantic blockers prevent executable output.

```text
paygen inspect INPUT [--profile FILE] [--format text|json] [--strict]
paygen init INPUT --output PROJECT
paygen generate PROJECT [--draft] [--set KEY=VALUE] [--save-profile FILE] [--watch]
paygen diff PROJECT [--check]
paygen update PROJECT NEW_INPUT
paygen explain PROJECT FACT_PATH
paygen patch add|replace|remove|copy PROJECT TARGET [--value JSON] [--from JSONPATH]
paygen recipe list|show|add|remove
paygen serve PROJECT [--scenario NAME] [--seed N] [--port 9292]
paygen verify PROJECT [--target http://127.0.0.1:9292] [--scenario-pack NAME] [--seed N]
paygen export PROJECT --standalone --output DIR
paygen architecture-check PROJECT
paygen doctor
```

Exit codes: 0 success, 1 failed check, 2 argument/project error, 3 invalid
specification, 4 unresolved semantics, 5 security denial, 70 internal error.
An exported standalone integration is detached from safe regeneration.

## Offline packs and runtime

NovaPay uses the original supplied contract plus explicit corrections. PayPal
Standard Payouts, Stripe Connect Payouts and Adyen Transfers v4 are curated
subsets with source and license provenance. See `fixtures/README.md`.

The reference runtime supports exact decimal conversion, stable payout identities,
ambiguous timeout results, explicit status transitions, callback verification and
credential rotation. Production integrations must supply durable state storage and
review their BaseService seam. PayPal's remote signature verification requires
an application hook; offline fixtures never pretend an unverified webhook passed.

The offline verifier exercises faults using real adapter calls. `--target` is
restricted to an explicit loopback HTTP simulator and reports remote smoke
coverage separately. No command in the default demo calls a live provider.

## Verification and documentation

```bash
bundle exec rspec
script/smoke
script/verify-complete
npm install --ignore-scripts
npm run docs:build
docker build -t paygen .
docker run --rm paygen doctor
docker build -f Dockerfile.docs -t paygen-docs .
docker run --rm -p 8080:80 paygen-docs
```

Ruby CI covers 3.3.12, 3.4.10 and 4.0.6. The Pages workflow is manual and has not
been deployed. Current evidence and remaining gates live in `VERIFICATION.md`
and `IMPLEMENTATION_STATUS.md`; do not equate a generated example with full plan
completion or live-provider certification.
