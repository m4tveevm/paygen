# Таблица технологий и инженерных решений

| Технология/механизм | Этап и задача | Почему подходит | Цена/ограничение | Минимальная альтернатива |
|---|---|---|---|---|
| Ruby 3.3+ / 4.x | CLI, core, generator, runtime | Соответствует host/кейсу; единая модель объектов | Dynamic typing требует runtime validation; evidence привязан к версии | Узкий Ruby script без IR |
| Psych/JSON stdlib protections | Input | Safe parse и отсутствие code execution | Нужны limits глубины/размера отдельно | JSON-only input |
| JSONSchemer 2.5 | OAS/JSON Schema, response schemas | Draft/OpenAPI modes, detailed errors | Schema validity не равна semantics | Ручные required/type checks |
| Janeway JSONPath 1.1 | Overlay/workflows | RFC 9535 selector engine и CTS | Complexity/time limits обязательны | Ограниченный JSON Pointer patch |
| Overlay 1.1 | Reviewable source correction | Не изменяет pinned upstream, ordered diff | Target может устареть | Редактировать копию spec |
| Ограниченный Arazzo 1.1 | Последовательности HTTP steps | Declarative workflow и dependencies | Не весь стандарт; untrusted extensions не задают policy | Ruby scenario DSL |
| Profile/recipe + provenance | Domain semantics | Явные units/status/conditions, traceable override | Требует экспертного review | Hardcoded provider adapter |
| BigDecimal | Money | Decimal exactness без binary Float | Нужна явная precision/rounding policy | Integer minor-only API |
| OpenSSL | HMAC/TLS primitives | Standard library, constant-time helper | Корректность зависит от exact bytes/encoding | Injected verifier library |
| RSpec/WebMock | Unit/integration tests | Observable HTTP without provider calls | Mock не доказывает remote behavior | Injected fake transport only |
| PropCheck 1.0.2 | Отдельные amount properties | Генерация/shrink в focused tests | Не product StateFuzzer | Таблица boundary examples |
| Собственный StateFuzzer | Stateful sequence/fault/replay | Domain actions и reducer под контролем | Bounded actions/seeds; не exhaustive | Handwritten sequences |
| Rack/Puma | Simulator/Demo local HTTP | Реальная loopback serialization boundary | Не provider sandbox | In-process Rack call |
| Diplodoc/npm | Published documentation | Проверяемая static docs build | Node toolchain дополнительно | Markdown only |
| Bruno | Executable collection smoke | Переносимые HTTP examples | Collection не проверяет adapter internals | curl script |
| OCI Dockerfiles + GitHub Actions | Reproducible CI/docs | Изолированные jobs and deploy artifact | Container ≠ production certification | Local `script/check` |
