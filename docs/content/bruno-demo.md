# Test an adapter with Bruno

The exported Bruno collection calls a local application that loads the generated
Ruby adapter. The adapter sends requests to a provider simulator and processes
callbacks through the backend hooks. Credentials, payouts and callbacks are
synthetic; the demo binds to loopback and keeps state in memory.

## Run the demo

From the repository root, with Ruby dependencies installed:

```bash
src/run cli init fixtures/novapay/openapi.yaml --output tmp/demo
src/run cli generate tmp/demo
src/run cli collection tmp/demo --format bruno --output tmp/demo-bruno
src/run cli demo tmp/demo --port 9293
```

Open `tmp/demo-bruno` in Bruno, select the `local` environment and run the requests
in order. The collection contains classic `.bru` files, matching `fixtures.json`
and a `paygen-collection.json` manifest with the effective configuration hash.
The export directory must be new and outside the project. Stale inputs, modified
generated files and projects with unresolved blockers must be corrected first.

Generation requires no Node or Bruno installation. For the command-line runner,
use Node 22.13 or later within Node 22 and pnpm 10.32.1. In a second terminal:

```bash
pnpm --dir tools/bruno install --frozen-lockfile --ignore-scripts
cd tmp/demo-bruno
node ../../tools/bruno/node_modules/@usebruno/cli/bin/bru.js run --env local --noproxy --bail --reporter-json results.json --reporter-junit results.xml
```

Use the default `success` scenario and run sequentially, without `--parallel`.
Each run creates fresh operation IDs and compares state before and after, so the
sequence can be repeated. Restarting the demo resets state. `baseUrl` can point
to another `http://127.0.0.1:PORT`; external targets are rejected.

## Collection checks

| Request | Expected behavior |
| --- | --- |
| Create | Returns a provider operation ID through the generated adapter |
| Retry | Preserves the ID without creating another provider record |
| Status | Reaches the configured result and preserves operation identity |
| Cancel, if configured | Cancels a separate pending operation |
| Invalid credentials, if configured | Receives HTTP 401 from the strict simulator |
| Signed callback | Accepts the exact signed body and rejects an invalid signature |
| Callback replay | Applies no second backend mutation |

Callback checks are generated for local HMAC-SHA256 and Stripe signatures.
Profiles using `provider_verification` require an application-supplied verifier
and omit these callback checks. Profiles without authentication or callbacks
omit the corresponding requests.

## Run the regression collection set

The repository pins Bruno CLI 4.1.0 separately from the documentation build.
From the repository root:

```bash
pnpm --dir tools/bruno audit --audit-level=high
src/run exec ruby script/verify-bruno.rb --cli tools/bruno/node_modules/@usebruno/cli/bin/bru.js --output tmp/bruno-verification
```

The runner starts and stops its own demos: NovaPay twice against the same state,
then Stripe, native Paystack and Raiffeisen. It saves JSON/JUnit reports and exits
nonzero on failure. The output directory must be new; omit `--output` for temporary
reports. `PAYGEN_NODE_EXECUTABLE` selects a different Node executable.

These checks cover the adapter, simulator and backend callback interface together.
Provider sandbox acceptance, real credentials and durable application state need
separate integration testing. See [provider configuration](native-onboarding.md)
for portable Markdown/HTML output and
[Bruno CLI options](https://docs.usebruno.com/bru-cli/commandOptions) for runner
options.
