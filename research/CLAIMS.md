# Реестр утверждений

Исторический реестр baseline `92ef59bc2c8eb102c7452136ee4ea8a46887fd52`: пути
и номера строк ниже относятся к этому снимку, а не к текущему дереву. Текущий
Ruby-код и тесты находятся в `src/lib/` и `src/spec/`; команды повторного запуска
приведены в [EXPERIMENTS.md](EXPERIMENTS.md) и
[development guide](../docs/content/development.md).

| claim_id | Формулировка | Тип | Источник / реализация | Evidence | Caveat |
|---|---|---|---|---|---|
| C01 | Основной продукт и generated service — Ruby; ML внутри продукта запрещён. | REQUIREMENT | [CASE], постановка роли | prompt summary | Разрешение developer-agent отдельно не доказано. |
| C02 | `request_method` означает logical gateway action, не HTTP verb. | REQUIREMENT | [Q&A] | prompt summary | Payment method и HTTP method — отдельные оси. |
| C03 | NovaPay HMAC-SHA256 считает exact raw body и передаёт hex в header. | REQUIREMENT | [Q&A] | prompt summary | Нужен host hook с raw bytes/headers. |
| C04 | OpenAPI описывает operations/parameters/security/schema, но не гарантирует domain semantics. | NORMATIVE + INFERENCE | OAS 3.0.3/3.1.1; paper §3 | SOURCES 1–2 | Вторая часть — вывод, не цитата стандарта. |
| C05 | Overlay actions применяются отдельно от immutable source snapshot. | IMPLEMENTED | `lib/paygen/core/overlay.rb`, `project.rb` @ baseline | RSpec baseline log | Реализовано поддерживаемое подмножество/limits. |
| C06 | Provenance хранит winning semantic origin. | IMPLEMENTED | `lib/paygen/core/ir.rb:33–36,376–382` | RSpec baseline log | Ruby Hash не называется immutable typed IR. |
| C07 | Generated drift блокирует regeneration; extensions сохраняются. | IMPLEMENTED | `lib/paygen/generator.rb:48–50,105`; project specs | RSpec baseline log | Extensions должен явно загрузить host. |
| C08 | Money conversion использует BigDecimal. | IMPLEMENTED | `lib/paygen/runtime/adapter.rb:343–357,524` | RSpec baseline log | Policy scale/precision всё равно semantic. |
| C09 | Callback verification имеет raw body/headers seam и fail-closed default. | IMPLEMENTED | `lib/paygen/runtime/adapter.rb:98–111,162–169`; docs generator | RSpec baseline log | Production BaseService integration не проверена. |
| C10 | Product StateFuzzer имеет собственные generation/shrink/replay mechanics; PropCheck применяется отдельно. | IMPLEMENTED | `lib/paygen/runtime/state_fuzzer.rb`; `spec/runtime_adapter_spec.rb:459–461` | RSpec baseline log | Не приписывается QuickCheck конкретная реализация. |
| C11 | Полный baseline suite: 1119/0, seed 1016, 89.46% line, 74.76% branch. | OBSERVED | baseline SHA | `evidence/rspec-baseline.log` | 703 examples — JSONPath CTS; не payment-test count. |
| C12 | Localhost HTTP path не доказывает provider sandbox/settlement. | INFERENCE | threat model, paper §§6–7 | architecture + test setup | Нужна внешняя проверка. |
| C13 | Общий generator снижает риск drift между code/docs/fixtures. | INFERENCE | paper §§4–5 | C06–C07; proposed consistency experiment | Common-mode semantic error остаётся. |
| C14 | Cross-process exactly-once не заявляется при default in-memory store. | INFERENCE | runtime architecture; paper §§2,7 | code review | Нужны durability/crash/transaction contracts. |
| C15 | Шесть независимых probes пяти baseline-дефектов A1–A5 проходят на clean `b878e17…`. | OBSERVED | `script/acceptance-independent` | `evidence/INTEGRATION_OBSERVATIONS.md`: 6/6 и hash raw report | Post-fix slice, не полное red/green исследование и не утверждение о последующем SHA. |
| C16 | Финальная release acceptance и необязательные исследования учитываются отдельно. | PROJECT POLICY | `EXPERIMENTS.md` | E06/E08 явно NOT_RUN; финальный release report добавляет собственный SHA | Не заявлены «все исследования завершены» или «все CI gates зелёные». |
| C17 | OAS 3.1 Schema Object согласован с JSON Schema dialect; OAS 3.0 имеет иной dialect. | NORMATIVE | OAS 3.0.3/3.1.1, JSON Schema 2020-12 | SOURCES 1–3 | Validator configuration должна учитывать версию. |
| C18 | Шифрование cardholder data само по себе не исключает PCI scope. | NORMATIVE | PCI SSC FAQ 1086 | SOURCES 11 | Фактический scope определяет assessor/архитектура. |
| C19 | E02–E05 выполнены: независимая byte equality, semantic YAML/JSON equality, drift/extension preservation, native onboarding без core edits. | OBSERVED | `script/research-experiments` на `954d1d1…` + hash скрипта | `evidence/INTEGRATION_OBSERVATIONS.md`; raw report под `tmp/research-experiments/` | Dirty research/script state записан; не final SHA и не произвольный provider. |
| C20 | Showcase имеет 150 PASS checks на clean `75e0331…`. | OBSERVED | `examples/showcase/run` | `evidence/INTEGRATION_OBSERVATIONS.md`: summary/hash/environment | В count входят команды и assertions, не 150 независимых payment scenarios. |
| C21 | Одна настоящая mutant failure сокращена 20→2 actions и повторена; обычный adapter проходит тот же trace. | OBSERVED | `examples/showcase/mutation.rb`, StateFuzzer, seed 4242 | E07; hashes mutant-failure/replay/fixed-replay | Нет matched-budget контроля и причинного вывода о превосходстве над stateless testing. |
| C22 | Дополнительный suite 1141/0, seed 42570 выполнен на `09013a6…` до последующих изменений. | REPORTED | Сообщение интегратора | Сохранённого raw log промежуточной сессии нет | Не архивированное evidence final SHA; финальный прогон должен иметь лог. |
