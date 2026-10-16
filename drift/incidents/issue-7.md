## Drift investigation

**Decision:** revert · **Risk:** High

### Findings
| Resource | Attribute | Declared | Live |
|---|---|---|---|
| `google_cloud_run_v2_service.internal` | `invoker_iam_disabled` | `false` | `true` |

The plan contains one action only: `update` in-place (`Plan: 0 to add, 1 to change, 0 to destroy`). There is no `delete` or `replace`. No other resource drifted. `google_cloud_run_v2_service.web` and `google_cloud_run_v2_service_iam_binding.internal_invoker` were refreshed with no reported changes.

### Evidence
- detect-drift job: https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/jobs/17221312716 (log checked: yes, by the investigator; matches issue: yes)
- Declared configuration: `terraform/main.tf` lines 56-61 (`drift-demo-internal`, `invoker_iam_disabled = false`). The comment on the resource reads "Internal API. Must require authentication; only the web service may call it." The invoker binding lists only `serviceAccount:${var.web_runtime_service_account}`.
- Job log (as reported by the investigator): `invoker_iam_disabled = true -> false` for `google_cloud_run_v2_service.internal`, followed by `OUT_OF_SYNC=true` and `DRIFT_DETECTED=true`.
- Human decision comments: none on this issue, so the normal decision rules apply.

### Analysis
- Risk of leaving it: the live setting is `invoker_iam_disabled = true` on `drift-demo-internal`, which is declared private. `terraform/main.tf` declares `ingress = "INGRESS_TRAFFIC_ALL"` for this service. The live ingress was not reported as drifted. Hypothesis: with IAM invoker checks disabled and that ingress setting, the internal API may be callable without authentication. This breaks the guardrail `drift-demo-internal must keep invoker_iam_disabled = false`.
- Risk of correcting it: the declared state sets `invoker_iam_disabled = false`, and the only declared invoker is the web service account. Hypothesis: any caller other than that service account that relies on unauthenticated access would start getting denied. The evidence shows no such caller. The correction is an in-place update with no delete or replace.
- Hypothesis: none about who made the change or why. The evidence does not show it.

### Proposed correction
Restore the declared configuration. `terraform/` is already correct, so no change to it is needed. This merge request only adds `drift/incidents/issue-7.md` with this report. Once merged, the reviewed `apply` will set `invoker_iam_disabled` back to `false` on `google_cloud_run_v2_service.internal`.

### Approval required
A human should review and merge the merge request, then run the manual `apply` job. After the apply, confirm that the next `detect-drift` run reports no drift.

### Uncertainty
- The evidence does not show who changed the setting, when, or why.
- The log shows only attributes that differ. It does not show whether the service was reached while IAM checks were disabled.
- The evidence does not show whether an unauthenticated caller was relying on the live setting.
- The log states "Declared changes pending: true", but the only pending change is the revert of this drift.
- The remediator had no job-log tool available and did not re-read the log itself. It relied on the issue evidence and the investigator's log check.
