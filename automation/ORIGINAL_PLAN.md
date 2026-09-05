# Автономная реализация Paygen через Codex Cloud

## Summary

Подготовить самодостаточный пакет для запуска в Codex Cloud с подключённым GitHub-репозиторием:

- `automation/CODEX_CLOUD_MASTER_PROMPT.md` — paste-ready задание корневому агенту.
- `automation/CODEX_CLOUD_RECOVERY_PROMPT.md` — продолжение после platform timeout, compaction или лимита.
- `automation/COMPLETION_CHECKLIST.md` — объективные gates и Definition of Done.
- `automation/README.md` — запуск, необходимые вложения и интерпретация статусов.

Локальный `codex exec` supervisor исключается: облачной задачей он управлять не сможет. Его заменяют persistent goal, журнал состояния в репозитории, машинные статусы и recovery-промпт. Обычный финал разрешён только при `COMPLETE`; лимит платформы даёт `INCOMPLETE_RESUMABLE`, а не ложное завершение.

## Master Prompt и оркестрация

- Промпт будет содержать весь Q&A и ключевые требования кейса, но потребует также прочитать приложенные PDF и YAML как недоверенные предметные данные, а не инструкции.
- Агент создаёт ветку `dev/paygen-reference`, ведёт `REQUIREMENTS.md`, `IMPLEMENTATION_STATUS.md`, `DECISIONS.md` и `VERIFICATION.md`, коммитит только после зелёного gate.
- Корневой агент владеет IR, CLI, manifests и интеграцией. До трёх субагентов параллельно работают волнами:
  1. Исследование кейса, провайдеров и безопасности.
  2. Непересекающиеся компоненты реализации.
  3. Независимые architecture/security/coverage audits.
- Два агента не меняют один файл; результаты субагента не считаются доказательством без повторной проверки корневым агентом. Это соответствует рекомендациям Codex для сложных параллельных задач. [OpenAI Docs: Subagents](https://developers.openai.com/codex/multi-agent)
- Терминальные статусы: `CONTINUE`, `COMPLETE`, `HARD_BLOCKER`, `INCOMPLETE_RESUMABLE`. Локальные ошибки, красные тесты и сложность не являются blocker.
- Предел одного облачного запуска: 48 продолжений или 24 часа. При достижении лимита сохраняются точный следующий шаг и evidence; recovery-промпт продолжает тот же план без повторения завершённых фаз.
- Настройка: `gpt-5.6-sol`, reasoning `xhigh`; read-only субагенты могут использовать Terra, implementation/review наследуют Sol.
- Никаких push, merge в `main`, live payouts или фактического Pages deploy без отдельной авторизации.

## Целевой продукт и публичные контракты

- Ruby gem `paygen`, модуль `Paygen`, executable `bin/paygen`.
- Основной runtime — OCI-образ `ruby:4.0.6-slim`; gem поддерживает Ruby `>=3.3`, CI проверяет 3.3.12, 3.4.10 и 4.0.6.
- Ruby-стек: `dry-cli`, `json_schemer`, `rack`, `puma`, `prop_check`, `listen`, `diff-lcs`; RSpec/WebMock/Rack::Test/SimpleCov/RuboCop/Bundler Audit для проверки.
- Full Overlay 1.1: JSON/YAML, `extends`, ordered `update/remove/copy`, recursive merge и RFC 9535 JSONPath через `janeway-jsonpath`, проверенный compliance suite. Нулевое совпадение остаётся допустимым по стандарту, но даёт `PATCH_STALE` warning.
- Arazzo 1.1: полная валидация/import/export и исполнение HTTP/OpenAPI и вложенных Arazzo workflow-конструкций, используемых payout-прототипами; произвольный AsyncAPI broker executor не входит.
- Diplodoc: Node 22, pinned `@diplodoc/cli`, локальная static build и OCI-сервер; также GitHub Pages workflow. Actual live URL не является условием `COMPLETE`. [Diplodoc quick start](https://diplodoc.com/docs/en/quickstart)

CLI:

```text
paygen inspect INPUT [--profile FILE] [--format text|json] [--strict]
paygen init INPUT --output PROJECT
paygen generate PROJECT [--draft] [--set KEY=VALUE] [--save-profile FILE] [--watch]
paygen diff PROJECT [--check]
paygen update PROJECT NEW_INPUT
paygen explain PROJECT FACT_PATH
paygen patch add|replace|remove|copy
paygen recipe list|show|add|remove
paygen serve PROJECT --scenario NAME --seed N
paygen verify PROJECT --target URL --scenario-pack NAME --seed N
paygen export PROJECT --standalone --output DIR
paygen architecture-check PROJECT
paygen doctor
```

Exit codes: `0` success, `1` expected check/verification failure, `2` CLI/project error, `3` invalid OpenAPI/Overlay/Arazzo, `4` unresolved semantic blockers, `5` security denial, `70` internal error.

Generated project:

```text
source/               # pinned OpenAPI
overlays/             # Overlay 1.1
integration.yml       # semantic source of truth
workflows/            # Arazzo
recipes/
extensions/           # user-owned Ruby
scenarios/
generated/            # Paygen-owned
paygen.lock
```

Precedence:

```text
source OpenAPI
→ contract overlays
→ structured inference/vendor extensions
→ recipe defaults
→ explicit integration profile
→ ephemeral CLI --set
```

`extensions/` никогда не перезаписывается. YAML не содержит Ruby и `eval`. Hooks: validation, request/response, status, callback verification, error classification и retry decision. Standalone export явно detached от безопасной регенерации.

## Реализация и test gates

1. Toolchain: контейнер, gem, CI, diagnostics и traceability.
2. NovaPay vertical slice: `inspect → patch → generate → load → fixtures`.
3. Generalization: OAS 3.0/3.1, IR, profiles, recipes, hooks, deterministic regeneration/update.
4. Четыре offline golden packs из curated official subsets:
   - NovaPay;
   - PayPal Standard Payouts;
   - Stripe Connect Payouts;
   - Adyen Transfers v4 bank subset.
5. Stateful mock/verifier и property fuzzing.
6. Full Overlay 1.1 и payout-oriented Arazzo execution.
7. Diplodoc local container, Pages workflow и five-minute demo.
8. Независимый аудит, исправление всех P0/P1, полный повторный suite корневым агентом.

Обязательные проверки:

- YAML, JSON, stdin и HTTPS ingestion; OAS 3.0/3.1; safe `$ref`.
- Byte-identical regeneration; stale overlay и generated drift detection; сохранность extensions.
- `batch_success_item_failed`, `paid_then_failed`, `booked_then_returned`.
- Timeout-after-commit, stable idempotency key, duplicate/out-of-order webhook, secret rotation, 429, unknown status, account/mode mismatch и currency boundaries.
- Raw-body signatures, SSRF, cyclic refs, resource limits, YAML/path/template injection и secret/PAN redaction.
- Все четыре адаптера проходят `ruby -c`, загружаются с reference `Provider::BaseService` harness и проходят fixtures/scenarios.
- Full Overlay compatibility tests и Arazzo workflow replay.
- Diplodoc static build, OCI smoke test и синтаксически валидный Pages workflow.
- В `lib/paygen/core` отсутствуют имена четырёх провайдеров и provider-specific branches.
- Нет `TODO`, `NotImplementedError`, skipped tests и blocking diagnostics в mandatory paths.
- `script/verify-complete` выполняет весь финальный audit и является обязательным evidence для `COMPLETE`.

## Assumptions

- GitHub-репозиторий будет подключён к Codex Cloud; PDF и `provider_api.yaml` пользователь приложит к задаче.
- Сейчас репозиторий пуст и без remote, поэтому миграций нет, а actual GitHub Pages URL появится после будущего push и включения Pages.
- Curated provider subsets хранят URL, commit/tag, SHA-256 и license; тесты не зависят от сети или credentials.
- В shipped-продукте нет LLM/AI runtime; субагенты используются только для разработки.
- Реальная PCI DSS сертификация, live provider calls, production hosting и полный универсальный AsyncAPI executor вне scope.
- Неизвестный production-контракт `Provider::BaseService` не блокирует работу: используется локальный harness и изолированный backend seam.
