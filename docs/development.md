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

This includes dependency audits, the documentation build, state-sequence tests,
Bruno HTTP tests and both container checks. The Ruby container also executes the
seven provider scenarios. The check installs locked Node dependencies and downloads
container images as needed. Bruno JSON and JUnit reports are written under
`tmp/bruno-verification/`. CI retains these reports on failure as well as success.

For seeded payment sequences and replaying a minimized failure, see
[payment verification](testing.md).

[GitHub Actions](https://github.com/m4tveevm/paygen/actions/workflows/ci.yml)
runs the Ruby suite on 3.3.12, 3.4.10 and 4.0.6. Workflow artifacts contain test
coverage, the built manual and integration results.

For focused commands and the local HTTP flow, see the
[demo](demo.md) and [Bruno guide](bruno-demo.md).

## Documentation

```bash
npm run docs:test
npm run docs:build
npm run docs:check
```

`docs:build` renders the manual, generates allowlisted NovaPay downloads with the
Ruby generator, validates internal links/assets for the `/paygen/` project Pages
prefix, rejects symlinks and forbidden paths, and writes
`publication-manifest.json`. The manifest binds the artifact to the source commit,
an HTML digest, and per-file SHA-256 values. The manual is built into
`docs/_build/`. To serve it using the documentation
container:

```bash
docker build -f Dockerfile.docs --build-arg PAYGEN_SOURCE_SHA=$(git rev-parse HEAD) \
  -t paygen-docs .
docker run --rm -p 127.0.0.1:8080:80 paygen-docs
```

Open `http://127.0.0.1:8080/paygen/`. To test the same prefix without a container,
copy `docs/_build` to a temporary server root as `paygen/`, serve that root, and
request `/paygen/`, `/paygen/provider-catalog.html`, a download, and a missing
path. The missing path must return 404 rather than a redirect to the home page.

Pull requests run the Pages build and artifact gate without deployment. A trusted
maintainer can manually dispatch **Publish documentation** with the full accepted
commit SHA. The workflow checks out that immutable SHA, rebuilds and revalidates
the artifact, then deploys it through the protected `github-pages` environment.
Configure the repository's Pages source as **GitHub Actions** first. Do not use a
moving branch name as the accepted ref.

Rollback is another normal dispatch using the full SHA of a previously reviewed
release. It rebuilds that revision and deploys its checked artifact; do not rewrite
branch history or reuse an unverified local archive.

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
