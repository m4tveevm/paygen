# Reproducible live showcase

The launcher creates four integration projects from checked-in focused contracts,
executes the generated Ruby adapters behind a real loopback HTTP application,
asserts outcomes, and keeps evidence. It uses only synthetic data and never
contacts a real provider. Ruby, Bash and Git are required; curl is not required.

## Prepare (network may be needed)

```bash
bundle install
```

## Run (warm/offline)

```bash
examples/showcase/run
# or choose a new empty output directory and a free loopback port
PAYGEN_DEMO_PORT=9393 examples/showcase/run tmp/my-showcase
# Allocate an OS-selected free loopback port for each disposable server:
PAYGEN_DEMO_PORT=0 examples/showcase/run tmp/automatic-ports
```

Every command is bounded to 60 seconds; server readiness is bounded to ten seconds.
The launcher refuses an occupied port and terminates only its owned process groups,
with a bounded TERM/KILL fallback. It refuses nonempty output directories, so use
a fresh output directory for another run. Ports, provider state and generated
projects are not shared between concurrent runs; choose port `0` for parallel runs.
Only loopback HTTP is used and ambient proxy configuration is ignored.

Do not click the panel during the automated run: it owns state used by its
assertions. For an interactive presentation, after the run finishes start one of:

```bash
bundle exec bin/paygen demo tmp/my-showcase/novapay --port 9393
bundle exec bin/paygen demo tmp/my-showcase/stripe --port 9394
bundle exec bin/paygen demo tmp/my-showcase/paypal --port 9395
bundle exec bin/paygen demo tmp/my-showcase/adyen --port 9396
```

Each page loads a provider-specific editable synthetic request. PayPal callback
verification remains an explicit host responsibility; its unverified events are
rejected. Adyen progress (`booked`) is not presented as approval. The terminal
showcase is authoritative and needs no browser.

## Observable acceptance

- Four generated, syntax-checked, drift-clean adapters; consecutive generations
  have identical managed-file hashes. Each adapter executes create/retry/status
  and invalid authentication through HTTP, not merely `generate`.
- NovaPay runs three operation sessions against the same application state.
  Each creates exactly one provider record and one outbound create; the request
  digest matches an independently specified `150000`-kopeck wire body.
- Invalid callbacks have no backend effect; duplicate signed terminal callbacks
  have exactly one effect. PayPal is checked fail-closed, not signature-verified.
- A separate strict provider HTTP probe rejects missing amount, string amount,
  and unsupported currency without creating a record. A valid control then
  creates one. This bypasses adapter prevalidation, not provider validation.
- A disposable project changes the minimum from 100000 to 200000 minor units
  through `configure --set` and ordered `patch replace` Overlay actions. Its
  explicit error examples and docs update; 1500 RUB is rejected without a commit
  and 2000 RUB is accepted. Pinned source and a user-owned extension note survive.
  This is a synthetic changed contract, not a claim about a real NovaPay change.
- `mutation.rb` creates an intentionally broken adapter **only in a disposable
  subprocess**. One singleton-method mutation forgets create reservations; the
  product has no bypass switch. The seeded fuzzer detects two actual commits,
  shrinks its own failing trace, and reproduces the failure from persisted bytes.
  The ordinary CLI replays that exact trace against the unchanged generated
  adapter and passes, with the same profile hash. No generated file is patched.

Key reports: `summary.json`, `commands.json`, `processes.json`, `environment.json`,
`tested-sha.txt`, `dirty-state.txt`, `novapay-artifact-sha256.json`, `*-run-*-*.json`,
`wire-*.json`, `adaptation.json`, `mutant-failure.json`, `mutant-replay.json`,
`mutant-trace.json`, `fixed-replay.json` and `fuzz.json`. Record both commit and
dirty state when archiving. `PASS` is emitted only after all assertions pass
and owned children are stopped. The two mutant failure reports correctly contain
`success: false`; that is the expected negative control, not an ignored failure.

## Optional container execution

Using the repository's existing image, override its CLI entrypoint:

```bash
docker build -t paygen-showcase .
mkdir -p tmp/container-showcase
docker run --rm --network none \
  --mount type=bind,source="$PWD/tmp/container-showcase",target=/evidence \
  --entrypoint examples/showcase/run paygen-showcase /evidence
```

The image build can require network access; the run uses only container loopback.
The build context excludes `.git`: the run records the actual source-file hashes
in `source-snapshot-sha256.json` and marks Git metadata unavailable instead of
inventing a tested commit. Archive the host commit/dirty state and image ID too.
An installed, reachable Docker daemon is required. An unexecuted container recipe
is not container-test evidence. Never mount production credentials or a Docker
socket into this demo.

The showcase does not prove PSP settlement, provider sandbox acceptance,
durable cross-process idempotency, PCI DSS compliance, all possible state
sequences, or compatibility with a closed production `BaseService` harness.
Focused fixtures remain distinct from native full-provider specifications.
