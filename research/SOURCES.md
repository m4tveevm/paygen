# Библиография и происхождение источников

Дата доступа ко всем веб-источникам: **2026-09-06**. Проверена доступность canonical URL (`curl -L`, HTTP 200); текст отчёта опирается на указанные разделы и локальные snapshots, но не воспроизводит vendor-тексты целиком.

1. OpenAPI Initiative. **OpenAPI Specification 3.0.3** (2020), §§4.6–4.8, 4.7.12, 4.7.24. https://spec.openapis.org/oas/v3.0.3.html — claims об OAS 3.0 document/paths/security/schema dialect.
2. OpenAPI Initiative. **OpenAPI Specification 3.1.1** (2024), §§4.6–4.8, Security Requirement Object, Schema Object. https://spec.openapis.org/oas/v3.1.1.html — OAS 3.1 и согласование с JSON Schema.
3. JSON Schema project. **JSON Schema Core and Validation, Draft 2020-12** (2022), Core §§7–8, Validation. https://json-schema.org/draft/2020-12 — schema validation и reference semantics.
4. OpenAPI Initiative. **Overlay Specification 1.1.0** (2024), §§4.3–4.5 (actions, target, update/remove). https://spec.openapis.org/overlay/v1.1.0.html — ordered non-destructive transformation.
5. IETF. Gössner, Normington, Bormann. **RFC 9535: JSONPath: Query Expressions for JSON** (2024), §§2–3. https://www.rfc-editor.org/rfc/rfc9535 — selector syntax/semantics.
6. OpenAPI Initiative. **Arazzo Specification 1.1.0** (2025), Workflow/Step/Runtime Expression sections. https://spec.openapis.org/arazzo/v1.1.0.html — workflow representation; реализация Paygen ограничена явно.
7. Claessen, K.; Hughes, J. **QuickCheck: A Lightweight Tool for Random Testing of Haskell Programs**. ICFP 2000. https://www.cs.tufts.edu/~nr/cs257/archive/john-hughes/quick.pdf — историческое основание property-based testing; не источник конкретного shrinker Paygen.
8. Van der Plas, Q. et al. **PropCheck: Property testing for Ruby**, repository/version reflected by `Gemfile.lock` (`prop_check 1.0.2`). https://github.com/Qqwy/ruby-prop_check — отдельные RSpec property tests; product `StateFuzzer` собственный.
9. Stripe. **Idempotent requests**, current API documentation. https://docs.stripe.com/api/idempotent_requests — пример provider-specific scope/retention/payload comparison, не универсальная норма.
10. Stripe. **Receive Stripe events in your webhook endpoint**, current documentation, signature verification/retries/event ordering sections. https://docs.stripe.com/webhooks — пример webhook raw body, replay/order concerns.
11. PCI Security Standards Council. **FAQ 1086: Are encrypted cardholder data in scope for PCI DSS?** https://www.pcisecuritystandards.org/faqs/1086/ — ограничение утверждений о masking/encryption и scope.
12. Paygen repository, commit `92ef59bc2c8eb102c7452136ee4ea8a46887fd52`: `Gemfile.lock`, `lib/paygen/core/*`, `lib/paygen/generator.rb`, `lib/paygen/runtime/*`, `spec/*`, `fixtures/*/provenance.json`. — IMPLEMENTED/OBSERVED claims и snapshot hashes/licenses.
13. [CASE] **«описание.docx.pdf» / provider_api.yaml**, пересказ в назначении роли; оригиналы в checkout не обнаружены. — требования NovaPay и rubric; отчёт не утверждает проверку оригинала.
14. [Q&A] **Уточнения организаторов**, дословно структурированный пересказ в назначении роли. — logical action, signature raw bytes, overrides, отсутствие production harness.

## Snapshot policy

Для provider snapshots authoritative provenance — соответствующие `fixtures/*/provenance.json` и `UPSTREAM-LICENSE`; SHA-256 проверяется тестами. Focused derived specs нельзя цитировать как полные vendor specs. В отчёт не копируются закрытые тексты, credentials или реальные реквизиты.
