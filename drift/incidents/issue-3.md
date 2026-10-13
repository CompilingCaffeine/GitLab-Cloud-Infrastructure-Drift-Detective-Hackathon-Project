# Drift incident: issue #3

## Drift investigation

**Decision:** adopt · **Risk:** Low

### Findings
| Resource | Attribute | Declared | Live |
|---|---|---|---|
| `google_cloud_run_v2_service.web` | `template.0.scaling.0.max_instance_count` | `2` | `4` |
| `google_cloud_run_v2_service.web` | `client` | (unset) | `"gcloud"` |
| `google_cloud_run_v2_service.web` | `client_version` | (unset) | `"588.0.0"` |
| `google_cloud_run_v2_service.web` | `last_modifier` | `"drift-apply@drift-detective-2026.iam.gserviceaccount.com"` (state) | `"(redacted user)"` |
| `google_cloud_run_v2_service.web` | `generation` / `observed_generation` | `"1"` / `"1"` (state) | `"2"` / `"2"` |
| `google_cloud_run_v2_service.web` | `latest_created_revision` / `latest_ready_revision` | `drift-demo-web-00001-btb` (state) | `drift-demo-web-00002-ln5` |
| `google_cloud_run_v2_service.web` | `traffic_statuses.0.revision` | `"drift-demo-web-00001-btb"` (state) | `"drift-demo-web-00002-ln5"` |
| `google_cloud_run_v2_service.web` | `etag`, `update_time`, `conditions.*.last_transition_time`, `terminal_condition.0.last_transition_time` | earlier values (state) | new values (server-generated bookkeeping) |

Only one resource is affected. The plan action is `update` in place (0 to add, 1 to change, 0 to destroy). There is no delete or replace. The `internal` service and the `internal_invoker` IAM binding show no drift.

### Evidence
- detect-drift job: https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/jobs/17133213754 (log checked by the investigator: yes; matches issue: yes. The remediator could not re-read the job log, because no job-log tool was available.)
- Declared configuration: `terraform/main.tf`, `google_cloud_run_v2_service.web`. `max_instance_count = 2` is on line 24. `client` and `client_version` are not declared.

### Analysis
- Guardrails: live `max_instance_count = 4` is at most 5. The `managed-by = terraform` label, `invoker_iam_disabled` and the invoker members are not in the drift. All guardrails hold.
- Risk of leaving it: the declared code (2) and the live service (4) stay out of sync. Every later plan proposes lowering capacity, and a routine `apply` would lower it by accident.
- Risk of correcting it (revert): the public web service's maximum capacity drops from 4 to 2 instances. That could reduce availability if the higher ceiling is serving load.
- Hypothesis: the change was a deliberate capacity increase made with the gcloud CLI, based only on `client = "gcloud"` and `last_modifier = "(redacted user)"`.
- Hypothesis: `client` and `client_version` are metadata that the gcloud CLI sets on every deploy, so they are not codified.

### Proposed correction
In `terraform/main.tf`, change `max_instance_count = 2` to `max_instance_count = 4` in `google_cloud_run_v2_service.web`. Do not codify `client` or `client_version`.

### Approval required
A human must review and merge this MR, then run the manual `apply` job. Whoever made the change (`(redacted user)` per `last_modifier`) should confirm that 4 is the intended ceiling. If it is not, choose revert instead.

### Uncertainty
- The reason for the change and the actual traffic load are not shown by the evidence.
- After adoption, the plan may still show `client`/`client_version` as `"gcloud"`/`"588.0.0"` -> unset. The next `apply` would clear them, and a later `gcloud` deploy would set them again. That could cause repeated low-risk drift reports.
