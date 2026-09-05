# Verify the generated adapter with Bruno

Paygen can export a Bruno collection from an already generated project. The
collection calls a local application that loads the generated Ruby adapter. The
adapter sends requests to a strict provider simulator and handles signed callbacks
through the reference backend hooks. The whole flow uses synthetic credentials.

```bash
bundle exec bin/paygen init fixtures/novapay/openapi.yaml --output tmp/demo
bundle exec bin/paygen generate tmp/demo
bundle exec bin/paygen collection tmp/demo --format bruno --output tmp/demo-bruno
npm ci --prefix tools/bruno --ignore-scripts --engine-strict
bundle exec bin/paygen demo tmp/demo --port 9293
```

In another terminal, from the repository root:

```bash
cd tmp/demo-bruno
node ../../tools/bruno/node_modules/@usebruno/cli/bin/bru.js run --env local --noproxy --bail --reporter-json results.json --reporter-junit results.xml
```

You can also open the collection directory in the Bruno application, select the
`local` environment, and run the requests in order. Generation itself requires no
Node or Bruno installation. The exporter emits supported classic `.bru` files;
Bruno also offers OpenCollection YAML. See the official
[format guide](https://docs.usebruno.com/bru-lang/overview) and
[CLI options](https://docs.usebruno.com/bru-cli/commandOptions).

The isolated `tools/bruno` runtime requires Node 22.13 or later within Node 22,
and npm 11. Its lock pins CLI 4.1.0 with patched dependency overrides, separately
from the documentation build. To reproduce all four provider regressions, including
two NovaPay runs against the same demo state:

```bash
npm audit --prefix tools/bruno --audit-level=high
bundle exec ruby script/verify-bruno.rb --cli tools/bruno/node_modules/@usebruno/cli/bin/bru.js --output tmp/bruno-verification
```

That runner starts and stops its own demos, installs no packages, saves JSON and
JUnit reports, and exits nonzero on failures. Its output directory must be new;
omit `--output` for temporary reports. `PAYGEN_NODE_EXECUTABLE` selects a Node
executable when it is not available as `node`.

The output directory must be new and outside the generated project. Paygen refuses
to export stale inputs, manually changed generated files, and diagnostic-only
drafts. The bundle includes the matching `fixtures.json` and a
`paygen-collection.json` manifest with the effective configuration hash.

## What the requests verify

| Check | Evidence |
| --- | --- |
| Create | The generated adapter returns a provider operation ID. |
| Retry | Reusing the operation preserves its provider ID and creates no extra provider record. |
| Status | Polls follow the configured success scenario and preserve identity. |
| Cancellation, when configured | A separate pending operation is cancelled before settlement. |
| Invalid credentials, when configured | The adapter reaches the strict simulator and receives an HTTP 401 error. |
| Supported callback signatures | The exact signed bytes are accepted; an invalid signature is rejected. |
| Callback replay | Repeated delivery has no second backend effect. |

Callback checks are generated for local HMAC-SHA256 and Stripe signatures. Profiles
using `provider_verification` need an application implementation of that hook;
these collections explicitly omit its callback checks. A profile without a
callback operation or provider authentication omits the corresponding checks.

Use the default `success` scenario. The sequence creates fresh short operation IDs
for each run and compares final evidence with its initial baseline, so runs can be
repeated. Run sequentially, without `--parallel`. The demo uses bounded in-memory
storage and resets when restarted. `baseUrl` may be changed to another
`http://127.0.0.1:PORT`; the collection rejects external targets.

## What remains to verify against a bank

This proves that the generated adapter, its configured contract, authentication,
idempotency, and backend callback boundary work together locally. Independent
official request/response examples and bank sandbox tests are needed to establish
that the profile describes the real provider correctly. The demo never connects to
a bank or executes a real payment. Real application persistence and production
backend hooks remain the application's responsibility.

Generated `INTEGRATION.md`, fixtures, and optional HTML documentation can travel
with each integration project. GitHub Pages hosts the Paygen manual and is optional
for those generated artifacts. The Bruno collection is another portable output
of the same effective configuration.
