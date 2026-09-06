# Reproducible live showcase

The launcher creates every integration project from its checked-in source, starts
the real Ruby demo application, makes loopback HTTP requests, runs assertions and
keeps its reports. It uses only synthetic data. It never contacts a provider.

## Prepare (network may be needed)

```bash
bundle install
```

## Run (warm/offline)

```bash
examples/showcase/run
# or choose a new empty output directory and a free loopback port
PAYGEN_DEMO_PORT=9393 examples/showcase/run tmp/my-showcase
```

The launcher bounds readiness to eight seconds, refuses an occupied port and
stops only the PID it started. Open `http://127.0.0.1:9293/` while it is running
to use the same-origin panel. The terminal path is authoritative and requires no
browser. Output JSON and SHA-256 files remain after shutdown.

The passing fuzzer run is product evidence. A deliberately broken adapter is not
included here: mutation must not become an ordinary runtime switch, and the
current fuzzer's replay binds a trace to the effective profile hash. Consequently
this pack does **not** claim the requested mutant-failure/fixed-pass comparison.
It also does not claim PSP settlement, provider sandbox acceptance, durable
cross-process idempotency, PCI DSS compliance, or compatibility with a closed
production `BaseService` harness.
