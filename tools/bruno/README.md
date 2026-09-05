# Isolated Bruno verification runtime

This directory pins Bruno CLI 4.1.0 and its dependency graph for Paygen's offline
HTTP regression tests. It is separate from the documentation toolchain and the
Ruby gem. Use Node 22.13 or later within Node 22, and npm 11.

From the repository root:

```sh
npm ci --prefix tools/bruno --ignore-scripts --engine-strict
npm audit --prefix tools/bruno --audit-level=high
bundle exec ruby script/verify-bruno.rb --cli tools/bruno/node_modules/@usebruno/cli/bin/bru.js --output tmp/bruno-verification
```

The output directory must be new. Omitting `--output` uses a temporary directory
that is removed after the run. `PAYGEN_BRUNO_CLI` can replace `--cli`;
`PAYGEN_NODE_EXECUTABLE` selects the Node executable and defaults to `node`.
The runner installs nothing. It starts each demo on an ephemeral loopback port,
executes Bruno in its safe sandbox, and returns nonzero if any check fails.

NovaPay runs twice against the same demo state, followed by Stripe, the complete
native Paystack contract, and the Райффайзенбанк profile. JSON, JUnit, logs,
configuration manifests, and a summary capture the evidence. All credentials,
payments and callback deliveries are synthetic. These tests do not contact banks.

## Dependency overrides

Bruno's upstream 4.1.0 dependency pins include known advisories. The isolated lock
uses patched versions:

| Dependency | Override |
| --- | --- |
| `@faker-js/faker` | 10.6.0 |
| `axios` | 1.20.0 |
| `form-data` | 4.0.6 |
| `nanoid` | 3.3.18 |
| `uuid` | 11.1.1 |

The generated collection scenarios pass with this graph. This verifies the Paygen
workflow; it is not a compatibility claim about every optional Bruno feature.
Run the audit and HTTP regression again when updating these pins. Do not replace
this lock with an implicit `npx` installation in CI.
