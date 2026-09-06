# Technologies and engineering decisions

| Technology or mechanism | Stage and purpose | Rationale | Cost or limitation | Minimal alternative |
| --- | --- | --- | --- | --- |
| Ruby 3.3+ / 4.x | CLI, core, generator, runtime | Matches the host and case requirements; one object model | Dynamic typing needs runtime validation; evidence is version-specific | A narrow Ruby script without IR |
| Psych/JSON standard-library protections | Input | Safe parsing without code execution | Separate depth and size limits are required | JSON-only input |
| JSONSchemer 2.5 | OpenAPI/JSON Schema and response schemas | Draft/OpenAPI modes and detailed errors | Schema validity does not establish semantics | Manual required/type checks |
| Janeway JSONPath 1.1 | Overlays and workflows | RFC 9535 selectors and compliance suite | Complexity and time limits remain necessary | Limited JSON Pointer patches |
| Overlay 1.1 | Reviewable source corrections | Ordered changes preserve the pinned upstream source | Targets can become stale | Edit a copy of the specification |
| Limited Arazzo 1.1 | HTTP step sequences | Declarative workflows and dependencies | Partial standard support; untrusted extensions cannot define policy | Ruby scenario DSL |
| Profiles/recipes and provenance | Domain semantics | Explicit units, statuses and conditions; traceable overrides | Requires expert review | Hardcoded provider adapter |
| BigDecimal | Money | Exact decimal arithmetic without binary Float | Explicit precision and rounding policy needed | Integer minor-unit-only API |
| OpenSSL | HMAC/TLS primitives | Standard library and constant-time helper | Correctness depends on exact bytes and encoding | Injected verification library |
| RSpec/WebMock | Unit and integration tests | Observable HTTP without provider calls | Mocks do not prove remote behavior | Injected fake transport only |
| PropCheck 1.0.2 | Focused amount properties | Generation and shrinking in focused tests | Separate from the product StateFuzzer | Boundary-example table |
| Custom StateFuzzer | Stateful sequences, faults and replay | Domain actions and reducer remain under project control | Bounded actions and seeds; not exhaustive | Handwritten sequences |
| Rack/Puma | Local simulator and demo HTTP | Real loopback serialization boundary | Not a provider sandbox | In-process Rack call |
| Diplodoc/pnpm | Published documentation | Validated static documentation build | Additional Node toolchain | Markdown only |
| Bruno | Executable collection smoke tests | Portable HTTP examples | Collections do not inspect adapter internals | curl script |
| OCI Dockerfiles and GitHub Actions | Reproducible CI and docs | Isolated jobs and deployment artifacts | Containers do not establish production certification | Local `script/check` |
