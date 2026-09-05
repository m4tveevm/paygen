# CLI reference

Run commands from a checkout as `bundle exec bin/paygen COMMAND`.
Use `bundle exec bin/paygen COMMAND --help` for command-specific options.

## Create and configure

```bash
bundle exec bin/paygen inspect provider.yaml --format json
bundle exec bin/paygen init provider.yaml --output tmp/provider
bundle exec bin/paygen configure tmp/provider
bundle exec bin/paygen configure tmp/provider --answers profile.yml
bundle exec bin/paygen configure tmp/provider --set operations.create=createPayout
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
bundle exec bin/paygen generate tmp/provider
bundle exec bin/paygen diff tmp/provider --check
bundle exec bin/paygen explain tmp/provider amount
bundle exec bin/paygen update tmp/provider provider-v2.yaml
bundle exec bin/paygen generate tmp/provider
```

`generate` writes the adapter, guide, fixtures and effective configuration. If
required decisions are missing, `generate --draft` writes diagnostics without an
executable adapter. `generate --watch` regenerates after input changes.

`diff --check` fails when generated output differs from current inputs or was
edited manually. `explain` shows where a configuration value came from. `update`
validates a replacement contract against existing corrections before pinning it;
generate and verify again after updating.

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
bundle exec bin/paygen verify tmp/provider --seed 42
bundle exec bin/paygen demo tmp/provider --port 9293
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
bundle exec bin/paygen docs tmp/provider --format html --output tmp/provider-html
bundle exec bin/paygen docs tmp/provider --format md --output tmp/provider-md
bundle exec bin/paygen collection tmp/provider --format bruno --output tmp/provider-bruno
bundle exec bin/paygen export tmp/provider --standalone --output tmp/provider-standalone
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
