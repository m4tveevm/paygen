# PR review follow-up

Reviewed PR #1 after its initial completion gate. The three inline GitHub
findings and seven additional reproduced defects are fixed. A separate review
of the authentication/source-update patch also checked operation-override scope
inference; its correction is included in the OAuth2 fix.

| Finding | Result and regression coverage |
| --- | --- |
| [OAuth2 inference](https://github.com/m4tveevm/paygen/pull/1#discussion_r3939997762) | Infer OAuth2 bearer credentials and required scopes from final outgoing operation selections across all semantic layers. Protected operations without usable auth produce a blocker. Tests verify token headers, scopes, missing credentials and callback separation. |
| [Replacement source identity](https://github.com/m4tveevm/paygen/pull/1#discussion_r3939997768) | Validate Overlay `extends` against the replacement path/URL; persist URI and SHA under the project write lock. Restore the source if writing the manifest fails. Tests check rejection without mutation and identity persistence through regeneration. |
| [OpenAPI server variables](https://github.com/m4tveevm/paygen/pull/1#discussion_r3939997771) | Expand declared defaults before selecting server mode and checking operation origins. Tests cover host, port and path variables, missing defaults, credential-bearing URLs and origin changes. |
| Mixed webhook ordering units | Compare sequence numbers with sequence numbers, or timestamps with timestamps. A signed timestamp-only event no longer suppresses a later numbered reversal. |
| Oversized response after payout creation | A response-size rejection preserves an ambiguous create outcome and returns the idempotency key with `reconcile_before_retry`. Preflight denials remain unambiguous. |
| Nested workflow state collisions | Scope workflow state by document identity so identical parent/child workflow IDs do not overwrite one another. |
| Payload replacement mutates inputs | Copy the resolved payload and replacement values before mutation; later requests retain the original inputs. |
| Embedded structured runtime values | Serialize embedded objects and arrays as JSON; preserve scalar and unparsed XML string behavior. |
| Workflow identifiers in runtime references | Resolve exact workflow/input/output/step keys, including hyphens and dotted output names. |
| Root-relative HTTPS Overlay references | Resolve `/source.yaml` against the remote overlay origin; retain absolute local path behavior. |

Validation results are recorded in VERIFICATION.md. The latest full matrix,
dependency audits and container gates are attached to
[PR #1 checks](https://github.com/m4tveevm/paygen/pull/1/checks).

Independent reproducers also exercised a real loopback POST whose 201 response
exceeded 1 MiB, and signed events using the actual Adyen configuration. The
former committed once and returned an ambiguous result requiring reconciliation;
the latter accepted the later returned event. No live payouts were issued.

Review scope covers the reported defects and their execution boundaries.
Application-owned durable state, backend integration and provider certification
retain the limits in docs/architecture.md and VERIFICATION.md.
