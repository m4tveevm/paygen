Источники: https://github.com/m4tveevm/paygen ; `docs/content/scope.md`; исторический commit `2bd28cf82bb0892dc192c7d5ac332cb9778e6140`; Stripe low-level errors и webhooks: https://docs.stripe.com/error-low-level, https://docs.stripe.com/webhooks

# Независимая проверка платёжной интеграции

Дата проверки: 2026-09-06. Все HTTP-сценарии suite используют контролируемый transport или локальный simulator; реальные платежи, credentials и production endpoints не используются.

## Результаты по важности

1. **DEFECT_FIXED_AND_VERIFIED — `src/run test` с одними опциями выполнял 0 тестов.** До исправления `src/run test --seed 29193` завершался с exit 0 и `0 examples, 0 failures`. Runner теперь задаёт RSpec явный `--default-path src/spec`; отдельный regression test проверяет как option-only, так и явный target.
2. **DEFECT_FIXED_AND_VERIFIED — HTTPS absolute self-reference терял retrieval identity.** Импорт документа с `$ref: https://provider.example/openapi.json#/...` ранее классифицировал ссылку как запрещённую внешнюю. Во время единственного разрешённого получения root URL теперь служит retrieval identity, ссылка на уже загруженный root превращается в локальный fragment, а сохранённый проект не содержит URL в schema references. После сериализации и переноса проект разрешается и генерируется без сети. Ссылка на другой HTTPS origin по-прежнему получает `REF_EXTERNAL_DENIED`; SSRF/redirect policy не менялась.
3. Исправления, перечисленные в постановке как исторические, перепроверены тестами актуальной ветки: положительные fixtures и ранняя media/auth диагностика (`generated_docs_spec`, `onboarding_spec`), вложенная profile validation и provenance (`onboarding_spec`), generated drift (`project_spec`). Ослабление проверок не потребовалось.

## A — слепое подключение

**NOT_DONE.** Текущая suite доказывает onboarding неизвестного title с явным profile и без выбора bundled recipe (`onboarding_spec`), но это контролируемая производная NovaPay, а не новый официальный публичный контракт. Поэтому она не выдаётся за требуемое независимое внешнее подключение. Кандидат Mollie `mollie/openapi` был получен 2026-09-06 на revision `12a599578b8ca79a6fe8439632d3f04260c047a4`; исходные 1,945,498 байт имели SHA-256 `b7497b77b18f19bd514a1041a489f930f2ad00b829843010bfccb6bf36f791d1`, а license в GitHub repository metadata отсутствовал. Снимок не добавлен и вывод о поддержке не сделан, поскольку полный inspect/configure/wire-oracle lifecycle в этой работе не завершён.

## B — скрытая привязка

**VERIFIED в существующем покрытии, частично относительно полного списка B1–B7.** `onboarding_spec` меняет title, добавляет нерелевантный recursive schema/endpoint и применяет явный profile; `project_spec` проверяет source/profile-driven diff. Полная отдельная матрица переименований B2–B6 не добавлена, поэтому результат не следует трактовать как доказательство всех семи преобразований.

## C — сопровождение

**VERIFIED для границ владения; NOT_DONE для исполняемого extension hook V1→V2.** `project_spec` доказывает атомарный update, diagnostics при overlay identity mismatch, сохранение extension, отказ перетирать ручную правку generated file и перенос detached project. Наличие extension не выдано за исполнение: отдельный полный сценарий с явно загруженным hook не выполнен.

## D — URL/self-reference

**DEFECT_FIXED_AND_VERIFIED.** Regression tests различают retrieval URL, переносимый root identity и schema `$id`, выполняют import → serialization → reload/resolve, а project lifecycle выполняет generate → move → regenerate с ровно одним контролируемым чтением URL. Arbitrary external refs остаются запрещены.

## E — платёжные гарантии

**VERIFIED в независимой in-process suite.** `payment_guarantees_spec` использует отдельный provider harness и проверяет наблюдаемые запросы/commit count, timeout-after-commit, стабильный provider key, mismatch параметров, подпись и дедупликацию callback, merchant isolation, stale polling, host failure/redelivery, concurrency и точные денежные значения. Граница доказательства — `MemoryStateStore`: suite не заявляет crash recovery или межпроцессную гарантию.

## Воспроизведение

```sh
src/run setup
src/run cli doctor
src/run test src/spec/input_spec.rb src/spec/project_spec.rb src/spec/run_script_spec.rb --seed 29193
src/run test src/spec/onboarding_spec.rb src/spec/payment_guarantees_spec.rb --seed 29193
src/run test --seed 29193
src/run lint
src/run package-test
src/run smoke
```

Проверяемый SHA следует фиксировать после commit (`git rev-parse HEAD`). Точные counts и exit codes должны браться из вывода свежего запуска, а не из этого документа. Реальный provider sandbox, host `Provider::BaseService` и durable state store остаются внешними границами.
