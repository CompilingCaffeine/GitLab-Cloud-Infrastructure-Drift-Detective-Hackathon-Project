---
name: drift-investigation
description: Investigate infrastructure drift reported by the drift-detect pipeline. Verify the evidence against the job log, classify risk, and decide whether to revert, adopt, or escalate. Use when an issue is labelled "drift" or contains a "Drift report".
---

# Drift investigation playbook

The declared OpenTofu configuration in `terraform/` on the default branch is the source of truth.
A drift issue is opened by CI. It contains a redacted drift report (Markdown and JSON) and the ID of
the `detect-drift` job that produced it.

You are started in one of two ways:
- by CI, with an assignment naming the issue and the `detect-drift` job, or
- by a human mentioning you on the issue. The assignment then looks like
  `Input: <their comment> Context: {Issue IID: <n>}`. Read that issue, and take the job ID from the
  issue description (or from the newest "Drift still present" comment, if there is one).

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

**Human decision first.** If a human (an author whose username does not start with `ai-`) has
commented on the drift issue with the exact text `decision: revert` or `decision: adopt`, and that
comment is newer than the latest "Drift investigation" comment, that is the decision. Name the human,
quote their comment, confirm the job log still shows the drift, and follow it, with one exception:
never adopt a live value that breaks a guardrail. In that case, explain why and escalate again.

If a human mentioned you but the comment does not contain `decision: revert` or `decision: adopt`
exactly, do **not** interpret it, even if the intent seems clear. Post one short comment that quotes
what they wrote and asks them to reply with the exact wording, then finish with `escalate`.
An infrastructure change needs an unambiguous instruction.

Otherwise, check the escalate conditions **first**: if any of them holds, the decision is escalate,
whatever the risk level.

- **escalate**: open no merge request; ask a human to decide. Use it when:
  - evidence is missing or contradictory,
  - the planned changes (what `apply` would do) contain `delete` or `replace`,
  - the drift changes a runtime identity (a service's `service_account`): reverting it could break a
    deliberate migration, and adopting it could legitimise lateral movement, so neither is safe to guess,
  - the drift involves secrets you cannot see, or you are unsure.
- **revert**: restore the declared configuration. Use it for every other High-risk drift (for example
  authentication disabled or invoker members changed) and for any drift you cannot justify adopting.
  The code is already correct, so the merge request records the incident and merging it lets the
  reviewed `apply` restore the declared state.
- **adopt**: codify the live value into `terraform/`. Use it only when **all** of these hold:
  - the risk is Low, or Medium with no security impact,
  - the live value satisfies every guardrail below,
  - reverting would plausibly reduce availability or capacity.

When you escalate, the "Proposed correction" section must lay out both options (revert and adopt),
what each would change, and what the human should check before choosing. End the "Approval required"
section with the exact reply that resumes the workflow:
`@ai-drift-detective-investigator-gitlab-ai-hackathon decision: revert` (or `decision: adopt`).

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
