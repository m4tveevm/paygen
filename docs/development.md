# Development

## Repository layout

Run the commands below from the repository root. Runtime implementation, schemas
and UI assets are in `src/lib/`, the CLI is `src/bin/paygen`, and packaged provider
recipes are in `src/recipes/`. The application container is `src/Dockerfile`;
the documentation container is `tools/docs/Dockerfile`. Both use the repository
root as their Docker build context.

Documentation, fixtures, examples, tests and research stay outside `src/`. Ruby
and npm manifests remain at the root. Generated integrations and detached
exports retain their own `lib/` and `recipes/` directories; those are output
formats, not paths to this repository's source.

## Toolchain

Paygen requires Ruby 3.3 or later. The repository pins Ruby 4.0.6 in
`.ruby-version` and Bundler 4.0.20 in `Gemfile.lock`.

```bash
gem install bundler -v 4.0.20
bundle install
bundle exec src/bin/paygen doctor
```

Node is needed only for building the project manual or running the Bruno CLI.
CI uses Node **22.22.0**, npm **11.9.0**, and the repository's pinned Ruby/Bundler.
The documentation build needs **both Ruby and Node**: Ruby produces the provider
downloads. Other Node 22 versions from 22.13 meet the package engine range, but use
the exact CI versions when comparing publication digests:

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
bundle exec ruby script/verify-package.rb
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

`docs:build` renders the manual, normalizes Diplodoc's random clipboard/TOC IDs,
and supplies the locked KaTeX CSS/fonts that the CLI bundle omits. It then runs
the Ruby generator for allowlisted NovaPay downloads and seals
`publication-manifest.json`. It validates links in the rendered DOM **and the
hydrated article JSON**, anchors, query-string links, TOC, CSS assets, and the
`/paygen/` project prefix. CI builds twice and compares the entire manifest.

`docs:check` is read-only: changed bytes, missing/extra files, a wrong provider
download hash or an invalid prefix fail instead of replacing the manifest.
The manifest binds the source commit, `html_sha256`, and each published file's
SHA-256. `artifact_sha256` hashes the sorted lines `SHA256 + two spaces + path`,
joined by a newline with no trailing newline; the manifest excludes itself.
This is a content digest, not a signed attestation or a Git commit SHA.

The manual is built into `docs/_build/`. To serve it using the documentation
container (requires Docker, network access for locked dependencies, and a clean
checkout matching the supplied source SHA):

```bash
docker build -f tools/docs/Dockerfile --build-arg PAYGEN_SOURCE_SHA=$(git rev-parse HEAD) \
  -t paygen-docs .
docker run --rm -p 127.0.0.1:8080:80 paygen-docs
```

Open `http://127.0.0.1:8080/paygen/`. To test the same prefix without a container,
copy `docs/_build` to a temporary server root as `paygen/`, serve that root, and
request `/paygen/`, `/paygen/provider-catalog.html`, a download, and a missing
path. The missing path must return 404 rather than a redirect to the home page.

Pull requests run the Pages build and artifact gate with read-only permissions;
they upload a **downloadable build artifact, not a live PR website**. They never
call Pages configuration or deployment. A maintainer can dispatch **Documentation
Pages** from the default branch with a full integrated `accepted_sha` and leave
`publish=false` to obtain an artifact and digest for review.

Pages source must be **GitHub Actions** in repository settings. Every push to
`main` builds and validates the Diplodoc manual in CI, uploads that exact Pages
artifact, and publishes it only after the Ruby matrix and integration job pass.
Pull requests do not publish. Only deployment jobs receive `pages:write` and
`id-token:write`; publication is serialized through `pages-publication`.

The `github-pages` environment still enforces any configured deployment rules.
Required reviewers, if enabled by an administrator, will pause deployment for
approval. Automatic Pages enablement is disabled.

The separate **Documentation Pages** workflow remains available for an explicit
manual release: use a full integrated `accepted_sha`, `publish=true`, and the
reviewed `accepted_artifact_sha256`. It requires successful push CI for that SHA,
builds twice and verifies the requested digest before deploying.

Rollback uses the same explicit procedure with the full integrated SHA and digest
of a previously accepted release compatible with this build pipeline. First do a
build-only dispatch and compare the reviewed digest. If a historical toolchain
cannot reproduce it, stop and review a corrected release; do not bypass the hash
gate, rewrite branch history or reuse an unverified archive.

The SHA in a local dirty-tree build identifies the checkout, not uncommitted
changes; do not publish such a build as an accepted release. In a source archive
(including Docker's build context without `.git`), `PAYGEN_SOURCE_SHA` is required
but cannot establish the archive's identity by itself. The protected workflow's
immutable clean checkout is the publication trust boundary.

The manual documents Paygen itself. Documentation for an individual integration
is generated with `paygen docs`; it can be viewed locally or published separately.

## CLI container

```bash
docker build -f src/Dockerfile -t paygen .
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
