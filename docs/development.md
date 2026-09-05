# Development

## Toolchain

Paygen requires Ruby 3.3 or later. The repository pins Ruby 4.0.6 in
`.ruby-version` and Bundler 4.0.20 in `Gemfile.lock`.

```bash
gem install bundler -v 4.0.20
bundle install
bundle exec bin/paygen doctor
```

Node is needed only for building the project manual or running the Bruno CLI.
Use Node 22.13 or later within Node 22, with npm 11.9.0:

```bash
npm install --global npm@11.9.0
npm ci --ignore-scripts --engine-strict
```

Both npm dependency trees are locked: the project manual uses `package-lock.json`,
and the optional Bruno runner uses `tools/bruno/package-lock.json`. The manual's
compatibility preload adapts the pinned Diplodoc dependencies to Node 22; its
tests cover those module interfaces and rendered output.

## Checks

Run the Ruby tests and the seven example profiles locally:

```bash
bundle exec rspec
script/smoke
bundle exec rubocop --only Lint,Security
bundle exec ruby script/architecture-audit.rb
```

`script/smoke` initializes each project in a temporary directory, generates it
twice, checks for drift and verifies its adapter. The suite covers NovaPay,
PayPal, Stripe, Adyen, native Paystack, native PayPal and Raiffeisen.

With Ruby, Node, npm, Docker and curl available, run the full CI checks:

```bash
script/check
```

This includes dependency audits, the documentation build, Bruno HTTP tests and
both container checks. It installs the locked Node dependencies and downloads
container images as needed. Bruno JSON and JUnit reports are written under
`tmp/bruno-verification/`.

[GitHub Actions](https://github.com/m4tveevm/paygen/actions/workflows/ci.yml)
runs the Ruby suite on 3.3.12, 3.4.10 and 4.0.6. Workflow artifacts contain test
coverage, the built manual and integration results.

For focused commands and the local HTTP flow, see the
[demo](demo.md) and [Bruno guide](bruno-demo.md).

## Documentation

```bash
npm run docs:test
npm run docs:build
```

The manual is built into `docs/_build/`. To serve it using the documentation
container:

```bash
docker build -f Dockerfile.docs -t paygen-docs .
docker run --rm -p 127.0.0.1:8080:80 paygen-docs
```

Open `http://127.0.0.1:8080/`. To publish the manual, configure the repository's
Pages source as **GitHub Actions**, then run the **Publish documentation**
workflow. The deployment job displays the published URL.

The manual documents Paygen itself. Documentation for an individual integration
is generated with `paygen docs`; it can be viewed locally or published separately.

## CLI container

```bash
docker build -t paygen .
docker run --rm paygen doctor
```

For the CLI demo with Ruby installed locally, follow the [quickstart](demo.md).
The container's entrypoint is `paygen`; arguments after the image name are passed
to the CLI.

## Changing an integration

Edit `integration.yml` for mappings and policies, `overlays/` for contract
corrections, and `extensions/` for application hooks. Regenerate and run `verify`
afterwards. Editing files under `generated/` causes a drift error.

Keep provider-specific behavior in profiles and recipes. When changing a fixture
snapshot, update its source metadata and SHA-256 in `provenance.json`, retain its
license, and run the affected contract tests.
