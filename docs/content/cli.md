# CLI reference

Run commands from a checkout as `src/run cli COMMAND`.
Use `src/run cli COMMAND --help` for command-specific options.

## Create and configure

```bash
src/run cli inspect provider.yaml --format json
src/run cli init provider.yaml --output tmp/provider
src/run cli configure tmp/provider
src/run cli configure tmp/provider --answers profile.yml
src/run cli configure tmp/provider --set operations.create=createPayout
```

`inspect` reads a contract without creating a project. Add `--strict` to return
exit code 4 when semantic blockers remain. `init` pins the source and creates a
project in a new directory; use `--profile FILE` to apply a prepared profile.

`configure` reports candidate operations, selected parameters and unanswered
questions. `--answers` merges YAML or JSON into `integration.yml`; `--set`
updates a specific setting. [Native onboarding](native-onboarding.md) explains
which decisions need provider documentation.

## Generate and maintain

```bash
src/run cli generate tmp/provider
src/run cli diff tmp/provider --check
src/run cli explain tmp/provider amount
src/run cli update tmp/provider provider-v2.yaml
src/run cli generate tmp/provider
```

`generate` writes the adapter, guide, fixtures and effective configuration. If
required decisions are missing, `generate --draft` writes diagnostics without an
executable adapter. `generate --watch` regenerates after input changes.

`diff --check` fails when generated output differs from current inputs or was
edited manually. `explain` shows where a configuration value came from. `update`
validates a replacement contract against existing corrections before pinning it;
generate and verify again after updating.

Run seeded payment sequences with `fuzz` and replay saved failures:

```bash
src/run cli fuzz tmp/provider --seed 42 --cases 100 --steps 30 --output tmp/fuzz.json
src/run cli fuzz tmp/provider --replay tmp/fuzz.json
```

The replay command accepts a failure report or trace. See
[payment verification](testing.md) for scope, limits and minimized counterexamples.

| Project path | Ownership and purpose |
| --- | --- |
| `source/` | Pinned API source |
| `integration.yml` | Your semantic profile |
| `overlays/` | Ordered contract corrections |
| `recipes/`, `workflows/`, `scenarios/` | Defaults and workflow descriptions |
| `extensions/` | Your Ruby hooks, preserved by regeneration |
| `generated/` | Paygen-managed adapter, documentation and fixtures |
| `paygen.lock` | Input and generated-file hashes |

For contract edits, `patch add`, `patch replace`, `patch remove` and `patch copy`
append Overlay actions. `recipe list` and `recipe show NAME` inspect bundled
defaults; `recipe add PROJECT NAME` and `recipe remove PROJECT` change selection.

## Verify and run locally

```bash
src/run cli verify tmp/provider --seed 42
src/run cli demo tmp/provider --port 9293
```

`verify` exercises the adapter with deterministic fault scenarios and prints a
JSON report. `demo` runs an HTTP application that invokes the generated adapter
against a provider simulator. Both require current generated files.

`serve PROJECT --port 9292` runs the provider simulator by itself. With it running
in another terminal, `verify PROJECT --target http://127.0.0.1:9292` performs an
HTTP smoke check. That check covers creation, retry and status; the default
offline verifier covers the fault scenarios.

`doctor` reports Ruby and dependency versions. `architecture-check PROJECT`
checks configuration consistency and generated-file ownership.

## Export

```bash
src/run cli docs tmp/provider --format html --output tmp/provider-html
src/run cli docs tmp/provider --format md --output tmp/provider-md
src/run cli collection tmp/provider --format bruno --output tmp/provider-bruno
src/run cli export tmp/provider --standalone --output tmp/provider-standalone
```

Export destinations must be new directories outside the integration project.
HTML includes `index.html` and the matching Markdown, effective OpenAPI and
examples. The [Bruno collection](bruno-demo.md) targets the local adapter demo.
Both exports need only Ruby.

`--standalone` copies the adapter and runtime into a separate, editable project.
Keep the original Paygen project for future regeneration: standalone changes
are maintained separately.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | A check failed or generated output changed |
| 2 | Invalid arguments or project |
| 3 | Invalid specification |
| 4 | Unresolved integration semantics |
| 5 | An input or path failed a security check |
| 70 | Internal error |
