# Bruno test runner

This directory pins Bruno CLI 4.1.0 for local HTTP regression tests, separately
from the Ruby gem and documentation build. It requires Node 22.13 or later within
Node 22 and npm 11.

From the repository root:

```sh
npm ci --prefix tools/bruno --ignore-scripts --engine-strict
npm audit --prefix tools/bruno --audit-level=high
bundle exec ruby script/verify-bruno.rb --cli tools/bruno/node_modules/@usebruno/cli/bin/bru.js --output tmp/bruno-verification
```

The output directory must be new. Omitting `--output` removes temporary reports
when the run finishes. `PAYGEN_BRUNO_CLI` can replace `--cli`;
`PAYGEN_NODE_EXECUTABLE` selects Node and defaults to `node`.

The runner starts demos on ephemeral loopback ports and runs Bruno in its safe
sandbox. It executes NovaPay twice against the same state, then Stripe, native
Paystack and Raiffeisen. JSON/JUnit reports, logs and a summary are saved to the
output directory. Failed checks return a nonzero exit status. No packages are
installed by the runner, and all requests use synthetic credentials and payouts.

## Dependency overrides

The lock applies patched versions to dependencies pinned by Bruno 4.1.0:

| Dependency | Version |
| --- | --- |
| `@faker-js/faker` | 10.6.0 |
| `axios` | 1.20.0 |
| `form-data` | 4.0.6 |
| `nanoid` | 3.3.18 |
| `uuid` | 11.1.1 |

When updating the lock, rerun the audit and collection checks. CI installs this
locked graph with `npm ci`; the generated Paygen collections cover the scenarios
in [the Bruno demo](../../docs/bruno-demo.md).
