# Bibliography and source provenance

Recorded access date for the web sources: **2026-09-06**. The historical check
followed canonical URLs with `curl -L` and received HTTP 200. The report draws on
the cited sections and local snapshots without reproducing full vendor texts.

1. OpenAPI Initiative. **OpenAPI Specification 3.0.3** (2020), §§4.6–4.8, 4.7.12, 4.7.24. https://spec.openapis.org/oas/v3.0.3.html — OAS 3.0 documents, paths, security and schema dialect.
2. OpenAPI Initiative. **OpenAPI Specification 3.1.1** (2024), §§4.6–4.8, Security Requirement Object, Schema Object. https://spec.openapis.org/oas/v3.1.1.html — OAS 3.1 and alignment with JSON Schema.
3. JSON Schema project. **JSON Schema Core and Validation, Draft 2020-12** (2022), Core §§7–8, Validation. https://json-schema.org/draft/2020-12 — schema validation and reference semantics.
4. OpenAPI Initiative. **Overlay Specification 1.1.0** (2024), §§4.3–4.5 (actions, target, update/remove). https://spec.openapis.org/overlay/v1.1.0.html — ordered, non-destructive transformations.
5. IETF. Gössner, Normington, Bormann. **RFC 9535: JSONPath: Query Expressions for JSON** (2024), §§2–3. https://www.rfc-editor.org/rfc/rfc9535 — selector syntax and semantics.
6. OpenAPI Initiative. **Arazzo Specification 1.1.0** (2025), Workflow/Step/Runtime Expression sections. https://spec.openapis.org/arazzo/v1.1.0.html — workflow representation; Paygen's implementation has explicit limits.
7. Claessen, K.; Hughes, J. **QuickCheck: A Lightweight Tool for Random Testing of Haskell Programs**. ICFP 2000. https://www.cs.tufts.edu/~nr/cs257/archive/john-hughes/quick.pdf — historical foundation for property-based testing, not the implementation source of Paygen's shrinker.
8. Van der Plas, Q. et al. **PropCheck: Property testing for Ruby**, repository/version recorded in the baseline `Gemfile.lock` (`prop_check 1.0.2`). https://github.com/Qqwy/ruby-prop_check — separate RSpec property tests; the product `StateFuzzer` is implemented independently.
9. Stripe. **Idempotent requests**, API documentation at the recorded access date. https://docs.stripe.com/api/idempotent_requests — a provider-specific example of scope, retention and payload comparison, not a universal rule.
10. Stripe. **Receive Stripe events in your webhook endpoint**, signature verification, retries and event ordering sections. https://docs.stripe.com/webhooks — raw-body, replay and ordering concerns.
11. PCI Security Standards Council. **FAQ 1086: Are encrypted cardholder data in scope for PCI DSS?** https://www.pcisecuritystandards.org/faqs/1086/ — limits on masking/encryption and scope claims.
12. Paygen repository, commit `92ef59bc2c8eb102c7452136ee4ea8a46887fd52`: `Gemfile.lock`, `lib/paygen/core/*`, `lib/paygen/generator.rb`, `lib/paygen/runtime/*`, `spec/*`, `fixtures/*/provenance.json`. — IMPLEMENTED/OBSERVED claims and snapshot hashes/licenses. Paths refer to that historical checkout.
13. [CASE] **Case description PDF / provider_api.yaml**, summarized in the original task assignment; the original files were not found in the checkout. — NovaPay requirements and rubric; the report does not claim to have inspected the originals.
14. [Q&A] **Organizer clarifications**, structured restatement in the original task assignment. — Logical actions, raw signature bytes, overrides and the absence of a production harness.

## Snapshot policy

Authoritative provider snapshot provenance is recorded in the corresponding
`fixtures/*/provenance.json` and `UPSTREAM-LICENSE`; tests verify SHA-256 hashes.
Focused derived specifications must not be cited as complete vendor contracts.
The report does not copy private texts, credentials or real payment details.
