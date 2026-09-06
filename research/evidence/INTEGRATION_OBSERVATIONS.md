# Integration observations — 6 сентября 2026

Это реестр **разных выполненных запусков**, не PASS финального merge. Исторические
baseline logs в этом каталоге не изменены. Указанные ниже raw integration artifacts
прочитаны локально, но находятся в ignored `tmp/` соответствующего checkout и
**не включены в Git этим документом**. Хеш идентифицирует прочитанные байты, но не
заменяет архив: перед передачей результатов следует сохранить каталоги evidence
или повторить команды и приложить новые логи. Числа разных запусков не складываются.

Команды ниже сохранены в форме, выполненной на указанных исторических SHA.
Для текущего дерева используйте `src/run exec ruby script/acceptance-independent`
и `src/run exec ruby script/research-experiments`; настройка описана в
[development guide](../../docs/content/development.md).

## Исторический baseline и промежуточный suite

- Архивированный baseline: `92ef59bc2c8eb102c7452136ee4ea8a46887fd52`,
  RSpec 1119/0, seed 1016; Linux x86_64, Ruby 3.4.4. См. `rspec-baseline.log`
  и существующий `SHA256SUMS`. Это не новая проверка текущей версии.
- REPORTED интегратором: `09013a6fb28ac258724c680eebb561901a64867f`,
  RSpec 1141/0, seed 42570, до последующих card/demo/других fixes. Raw log
  промежуточного запуска не сохранён; не представлять его как архивированный PASS.

## E10: независимая regression acceptance

- Source SHA: `b878e17f87939f834872fced178b3d3f768cceab`, dirty state: clean.
- Команда: `bundle exec ruby script/acceptance-independent`.
- Ruby 4.0.6, arm64-darwin25; injected transport, без provider network.
- Наблюдалось: 6 executed, 6 passed, 0 failed/skipped/blocked. Mutation controls
  внутри этого отчёта честно NOT_RUN; отдельный showcase ниже проверяет свою мутацию.
- Raw artifact: `paygen-integration/tmp/acceptance-independent/latest.json`.
- SHA-256: `41b6c96c378989087938f8af3b9eeb95bf3984b2e08f9982a20789a435087a37`.

Probes покрывают tenant namespace и scoped credential rotation, output-reference
preflight до HTTP, различимые progress events, decimal cache type и root filename
back-reference. Это post-fix slice, не повторное доказательство red/green каждого
исторического дефекта и не гарантия private backend.

## E07 / E09 slice: выполненный showcase

- Source SHA: `75e033165ff19ebb96c4d5bde0c491ed627264b7`, dirty state: clean.
- Команда: `examples/showcase/run tmp/integrated-showcase-1`.
- Ruby 4.0.6, Bundler 4.0.20, arm64-darwin25, synthetic loopback only, seed 4242.
- `summary.json`: status PASS, 150 checks, каждый PASS. Count включает commands
  и assertions; это не 150 независимых платёжных сценариев.
- Mutant: `success: false`, invariant `duplicate_payout`, 20 actions → 2 actions,
  13 shrink attempts. Persisted mutant replay снова `success: false` с тем же
  invariant. Fixed replay: `success: true`, 2 actions.
- Все три отчёта имеют один profile SHA:
  `afaea48b6e6ec1cd703204d8940fce869a8d103cec792bc05367d373b6abf8b0`.
- Raw directory: `paygen-integration/tmp/integrated-showcase-1/`.

| Raw file | SHA-256 |
|---|---|
| summary.json | `7c2afd5e0a6e58e7a3393b39b125b5ccdcdd4ef641ed960176a01368b15544c1` |
| tested-sha.txt | `53d8003c11d8f2ab9a2bdb477a54b21802020bba3e0b3ce16dac052bdaa7f271` |
| dirty-state.txt | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| environment.json | `71b88b25652fa5dceb6fa950759c29d0a49bbd16fbcc9f5ea2cd0e774f7f1624` |
| mutant-failure.json | `6911b83f090d1100ec58a3c7ac92999d81f3913f975ebe029ace6abb00b81f3d` |
| mutant-replay.json | `759d8bf8cfc689ab1c93015f5f8688cc59170f1d845a993d2e84f93d5cc48a69` |
| mutant-trace.json | `62fbcbf96c4016dc267a31617a778118d5ff4f38af8666e0f8ac38fd0c8193f3` |
| fixed-replay.json | `5f8af7907397744875e685b816d510302dc72a6d03beb3272e889e8f549b5e27` |

Одна намеренная mutation доказывает этот отрицательный контроль, shrinking и
replay; не даёт mutation kill rate полного corpus или matched-budget преимущества.
Showcase также проверяет часть invalid wire/callback cases, не все состояния.

## E02–E05: первый исследовательский прогон

- Source SHA: `954d1d19f1d6487e3d872a7d89d709fba16056e9`.
- Dirty state: только новый `script/research-experiments`; core был clean и
  остался byte-identical. Это до форматирования скрипта и до правок research docs.
- Script SHA-256 выполненных байтов:
  `58cc20aa9511586e27e2741e0b5aa3510fb51e4e5a691cb7afbd10a2d3914009`.
- Команда: `bundle exec ruby script/research-experiments`.
- UTC: `2026-09-06T09:04:35Z` — `2026-09-06T09:04:43Z`.
- Ruby 4.0.6, Bundler 4.0.20, arm64-darwin25, existing dependency cache,
  local files + WebMock; Node/container не использовались; native RSpec seed 42.
- E02: PASS, 7 generated files в каждом из двух независимых каталогов.
- E03: PASS, сравнение parsed IR/config/effective document/fixtures.
- E04: PASS, drift refusal сохранил ручные байты; реальное изменение profile
  изменило generated outputs и сохранило user-owned extension без исполнения.
- E05: PASS, native PayPal/Paystack create/status; native RSpec 14 examples,
  0 failures, 0 pending, 0 errors outside examples; core unchanged.
- Raw directory:
  `paygen-research/tmp/research-experiments/run-20260906T090435-26580/`.
- `report.json` SHA-256:
  `5e502061481d0d0567caa97367ae0a0a147a88011331315eeb8d6c15c8140ec3`.
- `artifact-sha256.json` SHA-256:
  `9f230cbdae68009f6602aef1139bffca46c55f01a30d6679b30dba5594cbb6e3`.

Скрипт исполняет конечный E02–E05 пакет и сохраняет новые hashes при каждом
запуске. E06/E08 в отчёте явно NOT_RUN. Финальный интегратор повторяет пакет
после сборки своего SHA; этот первоначальный отчёт не переименовывается в final.
