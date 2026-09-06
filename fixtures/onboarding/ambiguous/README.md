# Ambiguous onboarding fixture

This synthetic exercise derives from the fictional NovaPay assignment contract.
The title is changed so no bundled recipe matches. An additional
`createPayoutPreview` operation validates a preview without transferring funds;
`createPayout` is the actual creation operation. Similar names do not establish
payment semantics. The added operation is instructional, not an upstream API.

`partial-answers.yml` supplies monetary and response semantics but deliberately
leaves operation roles and authentication unresolved. `answers.yml` contains
the explicit decisions for this exercise. Its `amount.scale: 100` means major
input units become integer kopecks; `minimum: 100000` is in provider units.
`pending` is not settlement; only `completed` maps to `approved`.
The copied overlay supplies the same schema corrections as NovaPay.

Follow the dataset walkthrough in `docs/content/dataset-walkthrough.md`.
Use these answers only for this fixture, never as a generic provider template.
