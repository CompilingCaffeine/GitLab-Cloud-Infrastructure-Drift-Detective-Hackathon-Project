## Drift investigation

**Decision:** revert · **Risk:** High

### Findings
| Resource | Attribute | Declared | Live |
|---|---|---|---|
| `google_cloud_run_v2_service.internal` (service `drift-demo-internal`) | `invoker_iam_disabled` | `false` | `true` |

The plan action is `update` (0 to add, 1 to change, 0 to destroy). No `delete` or `replace`. No other resource drifted. `google_cloud_run_v2_service.web` and `google_cloud_run_v2_service_iam_binding.internal_invoker` were refreshed and show no changes.

### Evidence
- detect-drift job: https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/jobs/17133828431 (log checked: yes, by the investigator; matches issue: yes)
- The job log shows `invoker_iam_disabled = true -> false` in the plan, `OUT_OF_SYNC=true` and `DRIFT_DETECTED=true`. It was run on commit `e78144ae`.
- Declared configuration: `terraform/main.tf` lines 56-95 (`internal` service). Line 61 has `invoker_iam_disabled = false`, under the comment "Must require authentication; only the web service may call it." Lines 97-104 declare the authoritative `roles/run.invoker` binding. Its only member is the web runtime service account.

### Analysis
- Risk of leaving it: with `invoker_iam_disabled = true`, Cloud Run's IAM invoker check is bypassed for `drift-demo-internal`. Its ingress is declared as `INGRESS_TRAFFIC_ALL`. That would leave a service declared private open to unauthenticated callers. This also breaks the guardrail that `drift-demo-internal` must keep `invoker_iam_disabled = false`.
- Risk of correcting it: the change is an in-place update of one attribute. Cloud Run's IAM check is enforced again, and the declared binding allows only the web runtime service account. Any caller other than that service account would then be rejected. The evidence doesn't show any such caller, so it can't be ruled out. Capacity is not affected.
- Hypothesis: the setting was probably changed out-of-band, for example in the console or with gcloud. The evidence doesn't show who changed it or why.
- Note: `drift-demo-web` is declared with `invoker_iam_disabled = true` on purpose (`terraform/main.tf` lines 8-10, 15). That is not drift.

### Proposed correction
Restore the declared configuration. The code is already correct, so no change to `terraform/` is needed. This merge request only adds `drift/incidents/issue-4.md` with this report. Merging it lets the reviewed `apply` set `invoker_iam_disabled` back to `false`.

### Approval required
A human should review and merge the MR, then run the manual `apply` job. After that they should confirm that `drift-demo-internal` is private again and that the web service can still call it.

### Uncertainty
- Who or what changed the live value, when, and why are not shown by the evidence.
- It can't be determined whether anything legitimate has called `drift-demo-internal` without authentication since the change.
- The job log covers state vs. real world only. It doesn't show the IAM bindings' actual live members beyond "no changes" for the binding resource.
