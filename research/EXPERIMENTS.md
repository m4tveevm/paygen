# Воспроизводимые эксперименты

Исследовательская программа не является списком обязательных release gates. `NOT_RUN` у необязательного сравнительного исследования не блокирует прототип; наличие скрипта или CI job не означает выполненный PASS. Каждый результат относится только к записанным SHA, dirty state и окружению. Нельзя переносить его на новый merge SHA без повторного запуска.

## Исполняемый пакет E02–E05

```bash
bundle exec ruby script/research-experiments
```

Скрипт создаёт новый каталог `tmp/research-experiments/run-<UTC>-<pid>/`: `report.json`, `artifact-sha256.json`, stdout/stderr команд, проекты и native RSpec JSON. Можно передать явный **новый** каталог под `tmp/research-experiments/`; старое evidence не перезаписывается. Сохраняются SHA исходников и Gemfile.lock, hash исполняемого скрипта, Ruby/platform/Bundler, network/cache scope, seed, команды, exit codes и generated hashes. Значения окружения и реальные credentials не выгружаются. E05 использует checked-in синтетические HTTP oracles с WebMock, а не сеть провайдеров.

| ID | Проверка / oracle | Наблюдаемое свидетельство и граница |
|---|---|---|
| E01 | Полный RSpec: count/seed/coverage/exit | Исторический PASS: 1119/0, seed 1016 на `92ef59b…`, raw log `evidence/rspec-baseline.log`. Поздний 1141/0, seed 42570 на `09013a6…` сообщён интегратором без сохранённого raw log; это не финальный прогон. |
| E02 | Два независимых project dirs, один source/profile/version → одинаковый набор и SHA generated files | PASS пакета E02–E05 на `954d1d1…`; см. реестр ниже. Это не только повторная запись в тот же каталог. |
| E03 | Эквивалентные YAML/JSON → равные parsed IR/config/effective document/fixtures | PASS того же пакета. Provenance bytes, source identity, lock bytes и `config.source_hash` не входят в семантический oracle. |
| E04 | Generated edit → `GENERATED_DRIFT`, байты сохранены; profile change → regeneration, extension сохранён | PASS того же пакета. Extension не исполняется; контроль подтверждает изменение generated artifacts. |
| E05 | Native PayPal/Paystack + profiles → unchanged native source, generated adapters, independent HTTP examples | PASS того же пакета; `git diff HEAD -- lib` и hashes подтверждают отсутствие core edits. Selected create/status, не весь native API. |
| E06 | Matched-budget stateless/stateful mutation comparison | **NOT_RUN — необязательное будущее исследование**, не release gate. Причинное превосходство stateful fuzzing не установлено. |
| E07 | Реальная mutation → failure, shrink, replay; unchanged adapter → PASS того же trace | **OBSERVED, узкий slice:** showcase на clean `75e0331…`, seed 4242, `duplicate_payout`, trace 20 → 2, mutant replay FAIL, fixed replay PASS. Не весь mutation corpus. |
| E08 | Cold empty-cache setup и warm CLI timings, ≥5 repeats отдельно | **NOT_RUN — необязательное будущее исследование**, не release gate. Измеренное ускорение разработки и cold-start latency не заявлены. |
| E09 | Invalid amount/recipient/schema/signature → zero external calls / zero provider mutation | **PARTIAL OBSERVED:** showcase содержит отрицательные wire/callback controls, но не полную матрицу всех invalid cases. |
| E10 | Независимые regression probes A1–A5 с controls | **OBSERVED:** `script/acceptance-independent`, 6/6, clean `b878e17…`. Post-fix probes, не заново выполненное red/green сравнение исторических checkout. |
| E11 | Docs tests/build и проверки статических assets | Реализованы команды/gates; итоговый PASS требует свежих логов интегратора. Этот research-пакет Node/Docker/Pages не запускал. |

Полные SHA, окружения и hashes ранних integration artifacts перечислены в [реестре наблюдений](evidence/INTEGRATION_OBSERVATIONS.md). Последующий release report добавляет финальный SHA и свежие логи, а не переписывает историю. 703 JSONPath CTS примера в RSpec не являются платёжными сценариями.

## Предлагаемый, ещё не выполненный протокол E06

Перед будущим сравнением следует зафиксировать corpus, actions, общий action budget, seeds и правило подсчёта kills. Кандидаты: пропуск account scope; пропуск workflow dependency; callback dedupe только по mapped status; decimal type drift; неверная root-ref identity; unknown→approved; подпись reserialized body; unsafe create retry; отключённая response validation. Это **кандидаты будущего протокола**, не уже выполненные mutations.

Fixed examples запускаются отдельно. Stateful и stateless получают одинаковый бюджет. Метрика — уникальные killed mutations и воспроизводимые invariant violations, не число assertions. E07 подтверждает механизм на одной внесённой мутации, но не отвечает на сравнительный RQ4.

## Release acceptance отдельно от исследования

Практическое подтверждение интегрированной версии: полный RSpec, независимые regression probes, showcase/replay, docs gates и требуемые проектом smoke/контейнерные checks. Итоговые статусы собирает release report. Provider sandbox, приватный BaseService, durable storage и PCI assessment не подменяются локальным PASS и не входят в доказательство этих экспериментов.
