## Drift investigation

**Decision:** revert · **Risk:** High

### Findings
| Resource | Attribute | Declared | Live |
|---|---|---|---|
| `google_cloud_run_v2_service.internal` | `template.0.service_account` | `"drift-demo-internal@drift-detective-2026.iam.gserviceaccount.com"` (`var.internal_runtime_service_account`, default in `terraform/variables.tf`) | `"drift-demo-web@drift-detective-2026.iam.gserviceaccount.com"` |

Planned action if `apply` ran now: `update` in place on `google_cloud_run_v2_service.internal`, setting `template.0.service_account` back to `"drift-demo-internal@drift-detective-2026.iam.gserviceaccount.com"`. The log shows "Plan: 0 to add, 1 to change, 0 to destroy." There is no delete or replace.

### Evidence
- detect-drift job: https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/jobs/17134323580 (log checked: yes; matches issue: yes). The log and the issue agree on the drift, the plan and the commit `06c6d36d`. The drift is still present in the log.
- Declared configuration: `terraform/main.tf` lines 57-66 (`google_cloud_run_v2_service.internal`, `service_account = var.internal_runtime_service_account`). `terraform/variables.tf` sets `internal_runtime_service_account` to `drift-demo-internal@drift-detective-2026.iam.gserviceaccount.com` and `web_runtime_service_account` to `drift-demo-web@drift-detective-2026.iam.gserviceaccount.com`. The `internal_invoker` binding lists only the web service account as invoker.
- Human decision: @CompilingCaffeine commented "revert Checked: no migration planned; the internal API should keep its own identity." This comment is newer than the previous "Drift investigation" comment, which escalated. It was not written as the literal `decision: revert`. It is read as an unambiguous revert decision, and it answers the open question from the earlier escalation, which was whether a migration was planned.

### Analysis
- Risk of leaving it: the internal API, which is declared private, keeps running as the web service's identity (`drift-demo-web@...`) instead of its own. The web service is public (`invoker_iam_disabled = true`). Hypothesis: a shared identity could give the internal service the web service's permissions, or allow lateral movement. The evidence does not show the roles of either account.
- Risk of correcting it: the revert redeploys the internal service as `drift-demo-internal@...`. The human reports no migration is planned. Hypothesis: the internal service could depend on permissions that only `drift-demo-web@...` holds. The evidence does not show this either way.
- No guardrail is affected. The revert keeps `invoker_iam_disabled = false` on the internal service and keeps `managed-by = terraform`. It adds no `allUsers` or `allAuthenticatedUsers` invokers, and `max_instance_count` stays at 1.
- Hypothesis: none about who made the change or why. The evidence does not show an author or a cause.

### Proposed correction
Revert. `terraform/` stays unchanged, because the declared configuration is already correct. Applying it sets `template.0.service_account` back to `"drift-demo-internal@drift-detective-2026.iam.gserviceaccount.com"`.

### Approval required
A human reviews and merges this MR, then runs the manual `apply` job to restore the declared state. Nothing has been applied.

### Uncertainty
- Who changed the service account, when, and why. The evidence does not show it.
- The IAM roles held by `drift-demo-web@...` and `drift-demo-internal@...`. It is also unknown whether the internal service works under its own identity after the revert.
- The human reply did not use the exact `decision: revert` wording.
