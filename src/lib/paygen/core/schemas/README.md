# Vendored specification data

- `arazzo-1.1.json`: official OpenAPI Initiative Arazzo 1.1 schema,
  https://spec.openapis.org/arazzo/1.1/schema/2026-04-15 .
  Source repository `OAI/spec.openapis.org`, Git blob
  `c9c206d71a7158cffc07e56c7df34ceb440e838d`.
- `overlay-1.1.json`: official OpenAPI Initiative Overlay 1.1 schema,
  https://spec.openapis.org/overlay/1.1/schema/2026-04-01 .
  Source repository `OAI/spec.openapis.org`, Git blob
  `2f79a2511af6144f2236b581a116c9b928f0bdec`.
- These two schemas use Apache-2.0; see `OPENAPI-LICENSE.txt`.
- `jsonpath-cts.json`: complete 703-case JSONPath compliance suite from
  https://github.com/jsonpath-standard/jsonpath-compliance-test-suite
  at revision `b9d7153`, file `cts.json`. It uses BSD-2-Clause;
  see `JSONPATH-LICENSE.txt`. the checkout test `src/spec/overlay_spec.rb` executes every case,
  comparing values and normalized locations, including allowed order variants.

Schemas are vendored so validation does not depend on network access or a
moving upstream definition. OpenAPI document validation uses the official
schemas bundled by the pinned `json_schemer` gem.
