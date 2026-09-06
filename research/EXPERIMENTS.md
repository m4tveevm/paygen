# Воспроизводимые эксперименты

Все результаты должны содержать `tested_sha`, UTC time, OS/arch, Ruby/Node/Bundler/container versions, network mode, cache state, seed/budget и SHA-256 outputs. PASS запрещён при skipped/not_run.

| ID | Requirement / command outline | Expected / oracle | Baseline status |
|---|---|---|---|
| E01 | `bundle exec rspec` | 0 failures; сохранить seed/count/coverage | PASS, `evidence/rspec-baseline.log`, exit 0, SHA `92ef…52` |
| E02 | Два `paygen generate` в независимые temp dirs с одним source/profile/version; `sha256sum` каждого generated file | Byte-identical generated set | NOT_RUN (final RC отсутствует) |
| E03 | Эквивалентные YAML/JSON inputs → сравнить normalized config/artifact semantics | Semantically equal; provenance bytes не обязаны совпасть | NOT_RUN |
| E04 | Изменить generated file и regenerate; затем отдельно изменить `extensions/` | Drift отказ; extension сохранён | NOT_RUN standalone; suite содержит unit evidence |
| E05 | Native PayPal/Paystack profiles, `git diff --exit-code -- lib` | Executable onboarding без core change; unsupported честно перечислены | NOT_RUN standalone |
| E06 | Predeclared mutations × fixed examples × matched-budget stateless × stateful, одинаковые actions/seeds | Mutation kill matrix; state-specific incremental kills | NOT_RUN |
| E07 | Для каждого stateful failure сохранить original/shrunk/replay trace | Shrunk length ≤ original; replay same invariant | NOT_RUN |
| E08 | Cold empty cache install/setup и warm CLI startup, ≥5 repeats separately | Raw samples, median/range; no causal overclaim | NOT_RUN |
| E09 | Invalid amount/recipient/schema/signature с counting transport/store | Zero external calls and zero mutation before rejection | NOT_RUN standalone |
| E10 | Regression A1–A5 на tested RC SHA | Каждый reproducer красный до fix/зелёный после; control cases | NOT_RUN; не считать исправленными |
| E11 | `npm run docs:test && npm run docs:build` | No skips; static output built | NOT_RUN в research phase |

## Fault experiment protocol (E06)

До первого запуска записать mutation IDs: credential/account omitted from cache key; dependency edge omitted; callback dedupe by mapped status; JSON round-trip type drift; artificial root-ref identity; unknown status→approved; signature over reserialized body; retry unsafe create; response schema disabled. Corpus выбирается до результатов: NovaPay create/status/callback плюс минимум один provider с иным auth/status shape. На каждую группу выделяется одинаковый общий action budget. Seeds фиксируются списком, а не меняются после неудачи. Stateless control генерирует независимые одиночные actions в том же бюджете; fixed examples запускаются отдельно. Метрика — уникальные killed mutations и reproducible invariant violations, не просто число assertions.

## Handoff manifest

- role/phase/status: `03 / R0–R3 / READY_FOR_REVIEW`, final Results `BLOCKED_DEPENDENCY`;
- base/head at evidence: `92ef59bc2c8eb102c7452136ee4ea8a46887fd52`; branch `work`; dependencies_received: requirements summary only, no RELEASE_CONTRACT/RC;
- interface_version: `UNSPECIFIED`; changed paths: `research/**` only;
- exclusions: production code, QA criteria, docs TOC/Pages, provider network;
- environment: Linux x86_64 6.18.35, Ruby 3.4.4, Bundler lock toolchain 4.0.20 after install, Node 20.20.2, npm 11.4.2; WebMock blocks non-local network in tests;
- E01 cwd: repository root; expected 0 failures; observed 1119/0, seed 1016; PASS; log path above;
- source-access check: 11 URLs, `curl -L --max-time 25`, all HTTP 200; this is availability only;
- continuation: checkout the handed-off RC, then execute E02–E11 and update every OBSERVED row with tested SHA and raw artifact hash;
- reviewers: verify claims against `CLAIMS.md`, do not promote C15/C16 before evidence; role 05 may choose publication path, role 02 may use the executive summary for defense, role 00 owns evidence gaps.
