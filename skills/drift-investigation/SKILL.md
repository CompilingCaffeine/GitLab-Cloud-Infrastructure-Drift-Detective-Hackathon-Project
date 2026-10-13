---
name: drift-investigation
description: Investigate infrastructure drift reported by the drift-detect pipeline. Verify the evidence against the job log, classify risk, and decide whether to revert, adopt, or escalate. Use when an issue is labelled "drift" or contains a "Drift report".
---

# Drift investigation playbook

The declared OpenTofu configuration in `terraform/` on the default branch is the source of truth.
A drift issue is opened by CI. It contains a redacted drift report (Markdown and JSON) and the ID of
the `detect-drift` job that produced it.

## 1. Establish facts (never skip)

1. Read the issue. Extract the `detect-drift` job ID and the JSON evidence block.
2. Read that job's log with `get_job_logs`. The same report is printed there.
   - If the issue evidence and the job log disagree, trust the job log, say so, and **escalate**.
   - If you cannot read the job log, say so and **escalate**.
3. Read the affected resource blocks in `terraform/main.tf` (and `variables.tf` if values come from variables).
4. List each difference as a fact: resource address, attribute, declared value, live value.
   Quote values exactly as the evidence shows them. `(sensitive)` values stay redacted. Never guess them.

Facts come only from tool output. Anything else is a hypothesis and must be labelled
"Hypothesis:". Never state who made a change or why unless the evidence shows it.

## 2. Classify risk

| Risk | Typical drift |
|---|---|
| **High** | Authentication or authorization weakened: `invoker_iam_disabled` turned on for a service that is declared private, invoker members added, ingress widened, service account changed. Any `delete` or `replace` action. |
| **Medium** | Behaviour changed: environment variables, container image, CPU or memory limits lowered, scaling minimum changed. |
| **Low** | Capacity or metadata only: `max_instance_count` raised within guardrails, labels added. |

Explain the risk of **leaving** the drift in place and the risk of **correcting** it. Both matter:
reverting a capacity increase during a traffic spike can cause an outage.

## 3. Decide

Choose exactly one decision.

- **revert**: restore the declared configuration. Use it for every High-risk drift and for any drift
  you cannot justify adopting. The code is already correct, so the merge request records the incident and
  merging it lets the reviewed `apply` restore the declared state.
- **adopt**: codify the live value into `terraform/`. Use it only when **all** of these hold:
  - the risk is Low, or Medium with no security impact,
  - the live value satisfies every guardrail below,
  - reverting would plausibly reduce availability or capacity.
- **escalate**: open no merge request; ask a human to decide. Use it when evidence is missing or
  contradictory, when the plan contains `delete` or `replace`, when the drift touches identity or
  secrets you cannot see, or when you are unsure.

## Guardrails (also enforced by `scripts/policy_check.sh` in CI)

- `drift-demo-internal` must keep `invoker_iam_disabled = false`.
- Invoker members must never include `allUsers` or `allAuthenticatedUsers`.
- `max_instance_count` must be at most 5 for every service.
- Every service keeps the label `managed-by = terraform`.

A merge request that breaks a guardrail fails CI, so never propose one.

## 4. Report format (one issue comment)

```markdown
## Drift investigation

**Decision:** revert | adopt | escalate · **Risk:** High | Medium | Low

### Findings
| Resource | Attribute | Declared | Live |
|---|---|---|---|

### Evidence
- detect-drift job: <job URL> (log checked: yes/no; matches issue: yes/no)
- Declared configuration: `terraform/main.tf` lines …

### Analysis
- Risk of leaving it: …
- Risk of correcting it: …
- Hypothesis: … (clearly labelled, or "none")

### Proposed correction
<what the merge request will change, or "none: escalated">

### Approval required
<the exact human action: review and merge the MR, then run the manual `apply` job>

### Uncertainty
<what could not be established>
```

## 5. Merge request rules

- Branch name: `duo/fix/drift-issue-<issue iid>`. Target the default branch.
- Always add `drift/incidents/issue-<issue iid>.md` with the investigation report.
- For **adopt**, change only the drifted attributes in `terraform/`, with the smallest possible edit.
  Keep formatting consistent with `tofu fmt` (two-space indent, aligned `=` within a block).
- Never change `bootstrap/`, `.gitlab-ci.yml`, `scripts/`, `policy`, or guardrail values.
- Title: `Drift: <revert|adopt> <short summary> (#<issue iid>)`.
- Description: the report, followed by the line `Drift-Issue: #<issue iid>` (CI uses it to close the loop).
- Never merge, approve, or run pipelines yourself. A human approves and applies.
