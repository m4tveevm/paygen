# Development

For executable success and operator-review examples, adapter export, and the
`demo`/`serve` distinction, see [Run the datasets yourself](dataset-walkthrough.md).

## Repository layout

Run the commands below from the repository root. Runtime implementation, schemas
and UI assets are in `src/lib/`, the CLI is `src/bin/paygen`, and packaged provider
recipes are in `src/recipes/`. The application container is `src/Dockerfile`;
the documentation container is `docs/Dockerfile`. Both use the repository
root as their Docker build context.

Fixtures, examples and research stay outside `src/`. Ruby manifests, tests and
build settings live in `src/`; documentation dependencies and the pnpm lockfile
live in `docs/`. Generated integrations and detached
exports retain their own `lib/` and `recipes/` directories; those are output
formats, not paths to this repository's source.

`src/run` sets `BUNDLE_GEMFILE` to the application manifest and changes to the
repository root before executing. It works from any current directory when
called by its absolute path (or as `./run` from `src/`). Run `src/run package`
to build a gem in `src/`; `src/run rake` runs the configured Ruby suite.

## Toolchain

Paygen requires Ruby 3.3 or later. The repository pins Ruby 4.0.6 in
`src/.ruby-version` and Bundler 4.0.20 in `src/Gemfile.lock`.

`src/run` selects the Gemfile; it does **not** install or select Ruby. Since the
version file is inside `src/`, select that version explicitly when working from
the root. For example, with rbenv already installed:

```bash
rbenv install -s "$(cat src/.ruby-version)"
export RBENV_VERSION="$(cat src/.ruby-version)"
ruby -v
```

With another Ruby manager, select the same version using that manager, then:

```bash
gem install bundler -v 4.0.20
src/run setup
src/run cli doctor
```

Node is needed only for building the project manual or running the Bruno CLI.
CI uses Node **22.22.0**, pnpm **10.32.1**, and the repository's pinned Ruby/Bundler.
The documentation build needs **both Ruby and Node**: Ruby produces the provider
downloads. Other Node 22 versions from 22.13 meet the package engine range, but use
the exact CI versions when comparing publication digests:

```bash
mkdir -p "$HOME/.local/bin"
corepack enable --install-directory "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
corepack prepare pnpm@10.32.1 --activate
pnpm --dir docs install --frozen-lockfile --ignore-scripts
```

These commands place the Corepack shims in your user-owned directory, so a
read-only Node installation does not require administrator permissions. Corepack
must be available with the selected Node installation; `pnpm --version` should
print `10.32.1`.

Both pnpm dependency trees are locked: the project manual uses `docs/pnpm-lock.yaml`,
and the optional Bruno runner uses `tools/bruno/pnpm-lock.yaml`. The manual's
compatibility preload adapts the pinned Diplodoc dependencies to Node 22; its
tests cover those module interfaces and rendered output.

## Checks

Complete the Ruby and Node dependency setup above first. All commands below use
Bash and start at the repository root. Individual application runs need no Docker.


Run the Ruby tests and the seven example profiles locally:

```bash
src/run test
src/run package-test
src/run smoke
src/run lint --only Lint,Security
src/run audit --update
src/run exec ruby script/architecture-audit.rb
src/run exec ruby script/acceptance-independent
src/run exec ruby script/research-experiments
PAYGEN_DEMO_PORT=0 examples/showcase/run tmp/showcase-local
```

`tmp/showcase-local` must be new or empty. The acceptance runner overwrites
`tmp/acceptance-independent/latest.json`; set `PAYGEN_ACCEPTANCE_REPORT` to a
new filename when retaining multiple runs. Research experiments create a new
run directory below `tmp/research-experiments/`.

`src/run audit` explicitly checks `src/Gemfile.lock`; `--update` refreshes the
advisory database and needs network access. Running `bundler-audit check` at the
root does not select that lockfile through `BUNDLE_GEMFILE`.

`src/run smoke` initializes each project in a temporary directory, generates it
twice, checks for drift and verifies its adapter. The suite covers NovaPay,
PayPal, Stripe, Adyen, native Paystack, native PayPal and Raiffeisen.

With Ruby, Node, pnpm, Docker and curl available, run the full CI checks:

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

Author repository READMEs, guides and research prose in English. Preserve source
specifications, provider examples, licenses and historical raw logs in their
original form. Translate explanatory prose without changing recorded hashes or
claiming a new verification of historical evidence.

`404.md` is a hidden TOC entry: Diplodoc renders `404.html` for the hosting error
handler, but it is not a chapter. The publication check rejects a 404 navigation
entry while requiring the error page itself.

```bash
pnpm --dir docs run docs:test
pnpm --dir docs run docs:build
pnpm --dir docs run docs:check
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
docker build -f docs/Dockerfile --build-arg PAYGEN_SOURCE_SHA=$(git rev-parse HEAD) \
  -t paygen-docs .
docker run --rm -p 127.0.0.1:8080:80 paygen-docs
```

Open `http://127.0.0.1:8080/paygen/`. To test the same prefix without a container,
use Python 3 in another terminal after the build:

```bash
PAYGEN_PREVIEW_ROOT=$(mktemp -d)
cp -R docs/_build "$PAYGEN_PREVIEW_ROOT/paygen"
python3 -m http.server 8080 --bind 127.0.0.1 --directory "$PAYGEN_PREVIEW_ROOT"
```

Keep that terminal running. In a second terminal:

```bash
curl --noproxy '*' --fail http://127.0.0.1:8080/paygen/ -o /dev/null
curl --noproxy '*' --fail http://127.0.0.1:8080/paygen/provider-catalog.html -o /dev/null
curl --noproxy '*' --fail http://127.0.0.1:8080/paygen/downloads/novapay/manifest.json
curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}\n' \
  http://127.0.0.1:8080/paygen/does-not-exist
```

The final request must print `404`. Stop the server with Ctrl-C. Choose another
free port in both terminals if 8080 is already in use.

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
The container's entrypoint is `/app/src/run cli`; arguments after the image name
are passed to Paygen. Use `--entrypoint /app/src/run` before the image name to run
application tasks, for example `docker run --rm --entrypoint /app/src/run paygen test`.

## Changing an integration

Edit `integration.yml` for mappings and policies, `overlays/` for contract
corrections, and `extensions/` for application hooks. Regenerate and run `verify`
afterwards. Editing files under `generated/` causes a drift error.

Keep provider-specific behavior in profiles and recipes. When changing a fixture
snapshot, update its source metadata and SHA-256 in `provenance.json`, retain its
license, and run the affected contract tests.
