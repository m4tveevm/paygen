# Paygen

[![CI](https://github.com/m4tveevm/paygen/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/m4tveevm/paygen/actions/workflows/ci.yml?query=branch%3Amain)

[**Read the documentation →**](https://m4tveevm.github.io/paygen/)

Paygen generates Ruby payout integrations from OpenAPI 3.0/3.1 and a configuration
profile. It produces an adapter, integration documentation and test examples,
then checks the adapter against a local provider simulator.

The profile defines the decisions an API schema cannot reliably supply: which
operation sends money, how amounts and recipients are represented, which statuses
confirm settlement, and how retries and callbacks work.

## Quickstart

Use Bash and Ruby **4.0.6** (the checkout's pinned version); supported Ruby
versions start at 3.3. Ruby must already be installed and selected in your shell.
The version file is `src/.ruby-version`: a version manager running at the repository
root will not automatically discover it. See [toolchain setup](docs/content/development.md#toolchain).

Run from a fresh checkout:

```bash
git clone https://github.com/m4tveevm/paygen.git
cd paygen
gem install bundler -v 4.0.20
src/run setup
src/run cli doctor
src/run cli init fixtures/novapay/openapi.yaml --output tmp/novapay
src/run cli generate tmp/novapay
src/run cli diff tmp/novapay --check
src/run cli verify tmp/novapay --seed 42
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
src/run cli docs tmp/novapay --format html --output tmp/novapay-docs
src/run cli collection tmp/novapay --format bruno --output tmp/novapay-bruno
src/run cli demo tmp/novapay --port 9293
```

Open `tmp/novapay-docs/index.html` in a browser. In Bruno, open
`tmp/novapay-bruno`, select the `local` environment and run the collection in
order. The demo invokes the generated adapter, checks its requests in the provider
simulator, and processes signed callbacks. It listens on `127.0.0.1` and uses
synthetic credentials and payment data.

HTML and collection generation require only Ruby. Node is needed for the optional
Bruno CLI and the Paygen manual's site build. Export directories must be new.

## Configure another API

The following is a template for your own inputs: replace `provider.yaml` with an
existing OpenAPI file and `profile.yml` with your reviewed YAML/JSON profile.
Neither filename is bundled. For a copyable example using supplied files, follow
[native onboarding](docs/content/native-onboarding.md).

```bash
src/run cli init provider.yaml --output tmp/provider
src/run cli configure tmp/provider
src/run cli configure tmp/provider --answers profile.yml
src/run cli generate tmp/provider
src/run cli verify tmp/provider --seed 42
```

`configure` lists candidate operations, source locations and unanswered questions.
Resolve these in `integration.yml` or apply a profile before generating executable
code. Change the source, profile or overlays to regenerate; put custom Ruby hooks
in `extensions/`. Paygen detects manual changes to generated files.

Examples include NovaPay, Stripe, Adyen, PayPal, Paystack and Raiffeisen SBP
payouts. The [example catalog](fixtures/README.md) distinguishes full source
contracts from focused fixtures. T-Bank and Tochka illustrate signing and workflow
requirements that need additional integration work.

## Reproducible generation

The same normalized contract, reviewed profile, ordered overlays, selected recipe
and locked generator/toolchain versions produce the same files under `generated/`,
independently of the output directory. Generation does not use an LLM or live
provider responses. Changing one of these inputs can change the result.

OpenAPI alone can leave payment decisions unresolved. In that case Paygen emits
diagnostics and blocks executable generation; it does not guess amount units,
settlement statuses or safe retry rules. Import parses the source and stores
canonical JSON in `source/openapi.json`; `paygen.lock` hashes that normalized
contract. Formatting changes, YAML comments and equivalent YAML/JSON can therefore
produce the same source hash and provenance. This is not an original-file checksum;
retain the original file and its own checksum separately when byte-level audit
identity is required.

Run the independent-directory and semantic-equivalence checks after Ruby setup:

```bash
src/run exec ruby script/research-experiments
```

The published Diplodoc site is the product manual. `src/run cli docs PROJECT`
exports the guide for a particular generated integration. Those exports use the
project's effective contract; the site's 404 page is only an error handler.

## Documentation

- [Published Diplodoc manual](https://m4tveevm.github.io/paygen/).
- [Seven-minute demo](docs/content/demo.md): commands and expected results for a walkthrough.
- [CLI reference](docs/content/cli.md): configuration, generation and exports.
- [Native API onboarding](docs/content/native-onboarding.md): profiles and the API corpus.
- [Provider catalog](docs/content/provider-catalog.md): evidence levels and generated synthetic downloads.
- [Bruno demo](docs/content/bruno-demo.md) and [Russian bank examples](docs/content/ru-bank-examples.md).
- [Payment verification](docs/content/testing.md): seeded sequences, shrinking and replay.
- [Architecture](docs/content/architecture.md), [supported scope](docs/content/scope.md) and [development](docs/content/development.md).

The prototype demonstrates generation and local adapter behavior. Connecting a
real application also requires its `Provider::BaseService` hooks, durable state
storage and provider sandbox verification. Generated integration guides can be
distributed with the adapter; GitHub Pages is an optional host for the Paygen manual.

## Development

For an automated presentation with saved evidence, run
`examples/showcase/run tmp/showcase` after installing Ruby dependencies. It
demonstrates four local profiles, contract adaptation and a deliberate fuzz
failure → shrink → replay → fixed replay. See the
[presenter guide](examples/showcase/README.md) for scope and prerequisites.

```bash
src/run test
src/run package-test
src/run smoke
```

Build the Diplodoc manual after selecting Node **22.22.0**:

```bash
mkdir -p "$HOME/.local/bin"
corepack enable --install-directory "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
corepack prepare pnpm@10.32.1 --activate
pnpm --dir docs install --frozen-lockfile --ignore-scripts
pnpm --dir docs run docs:test
pnpm --dir docs run docs:build
```

The full build needs the Ruby dependencies installed above. It writes
`docs/_build/`, including the generated provider downloads and integrity manifest.
The [development guide](docs/content/development.md#documentation) explains local
preview under `/paygen/` and publication after successful `main` CI.

See the [development guide](docs/content/development.md) for the complete checks,
documentation build and containers.

Paygen is licensed under [MIT](LICENSE). Third-party API snapshots keep their
source and license information alongside the fixtures.

## Repository layout

Run checkout commands from the repository root. Application implementation and
runtime assets live together in `src/`; generated integration projects keep their
own layout.

| Path | Contents |
| --- | --- |
| `src/lib/` | Ruby core, generator, runtime and bundled schemas/UI assets |
| `src/bin/paygen` | CLI entrypoint |
| `src/recipes/` | Built-in provider recipes shipped with the gem |
| `src/Dockerfile` | CLI container; build with `docker build -f src/Dockerfile -t paygen .` |
| `docs/` | Diplodoc package, pnpm lockfile, content, scripts, Dockerfile and ignored `_build/` output |
| `fixtures/` | Provider snapshots, profiles, licenses and provenance |
| `src/spec/`, `acceptance/` | Unit/contract tests and independent acceptance corpus |
| `examples/` | Runnable showcases and presenter guides |
| `script/`, `tools/bruno/` | Cross-project verification and the optional Bruno CLI package |
| `research/` | Research reports and historical integration evidence |

Ruby manifests, tool versions, tests and build configuration live in `src/`.
`src/run` provides `setup`, `cli`, `test`, `lint`, `audit`, `package`, `package-test`,
`smoke`, `rake` and `exec`; it always resolves paths from the repository root.
The docs package and `pnpm-lock.yaml` live in `docs/`; its manual sources are in
`docs/content/` and build helpers in `docs/scripts/`. Bruno has its own pinned
pnpm package in `tools/bruno/`. See [development](docs/content/development.md)
for installation and the complete checks.
