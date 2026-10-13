# Evaluation

Four controlled scenarios were run on 2026-10-13 against the live demo environment on Google Cloud
(`drift-detective-2026`, `us-central1`). Every number below comes from GitLab job, issue, and merge
request timestamps or Cloud Run revision timestamps. Nothing is estimated.

These are single runs, not a statistical benchmark. They show that the workflow behaves as
designed end to end, including where it must refuse to act.

## Scenarios

| # | Out-of-band change | Expected | Agent decision | Risk | Result |
|---|---|---|---|---|---|
| 1 | Web service `max_instance_count` 2 → 4 with `gcloud` (capacity increase) | adopt | **adopt** | Low | MR [!1](https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/merge_requests/1) codified `4`; verified; issue #3 closed |
| 2 | Internal API authentication disabled (`invoker_iam_disabled` false → true) | revert | **revert** | High | MR [!2](https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/merge_requests/2) recorded the incident; apply restored auth; verified; issue #4 closed |
| 3 | None (clean environment) | no action | **no issue, no flow run** | n/a | Detection reported "No changes"; no issue, MR, or agent session created |
| 4 | Internal API runtime identity swapped to the web service account | escalate | **escalate**, then **revert** on human decision | High | No MR until a human replied `@…investigator … revert`; MR [!3](https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/merge_requests/3); verified; issue #5 closed |

| Check | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| Drift detected correctly (no false positive or negative) | ✅ | ✅ | ✅ | ✅ |
| Findings match the `detect-drift` job log (agent cross-checked) | ✅ | ✅ | n/a | ✅ |
| Decision matches the playbook | ✅ | ✅ | n/a | ✅ |
| Proposed MR passed fmt, validate, tests, policy | ✅ (after fix, see below) | ✅ | n/a | ✅ |
| Human approved before any infrastructure change | ✅ | ✅ | n/a | ✅ |
| Post-apply verification: plan shows no changes | ✅ | ✅ | ✅ | ✅ |
| Issue closed automatically with links to evidence | ✅ | ✅ | n/a | ✅ |

External checks after scenario 2 and 4: anonymous requests to the internal API returned **403**
(200 while drifted in scenario 2), and the public web service returned **200**, as declared.

## Timings

All times UTC. "Agent" is from issue creation to the merge request (or escalation comment).

| Stage | 1 | 2 | 4 (escalation) | 4 (after human decision) |
|---|---|---|---|---|
| Drift-check pipeline → evidence issue opened | 40 s | 46 s | 58 s | n/a |
| Agent investigation comment posted | +72 s | +64 s | +78 s | +72 s after mention |
| Agent merge request opened | +113 s | +97 s | none (escalated) | +104 s after mention |
| Apply start → verified and issue closed | 46 s | 68 s | n/a | 63 s |

Scenario 3 (no drift) finished in 46 s and started no agent session, so it used no GitLab Credits.

**Exposure window in scenario 2** (authentication off → back on): 09:02:09 → 09:14:05, **11 min 56 s**.
That breaks down as 3 min 3 s from the change until the agent finished (17 s before the schedule was
started by hand, then 2 min 46 s of automated detection and investigation), 8 min 17 s of human review
and merge, and 36 s of apply.

### Caveats

- **Detection latency.** In each run, the drift-check schedule was started by hand right after the
  drift was made. In normal operation it runs every 6 hours (`0 */6 * * *`), so detection can take up
  to 6 hours. The automated part *after* detection is what was measured above.
- **Scenario 1 human time is not representative.** Merging waited while CI issues found by this run
  were fixed (see below), so its review time is excluded.
- **Scenario 4 used a clarified playbook.** Before the run, the skill was changed to make escalation take
  precedence and to define identity drift. Without that, "revert every High-risk drift" and "escalate on
  identity changes" conflicted.
- **Loose human wording.** In scenario 4 the human wrote `revert` without the `decision:` prefix. The
  agent accepted it as an unambiguous decision, but recorded that the wording differed from the playbook.
  Afterwards the playbook was tightened: the agent now asks for the exact `decision: revert|adopt`
  wording instead of interpreting it.

## Defects found by the evaluation (all fixed)

| Found in | Defect | Fix |
|---|---|---|
| Phase 1 probe | The agent's `gitlab_api_get` tool returns empty data for raw (non-JSON) artifacts | Evidence goes in the issue body and the job log; the agent cross-checks the two |
| First plan | Report rendered once per resource (jq string concatenation with a generator) | Join sections; regression test |
| First plan | A first deploy was labelled "drift" | Separate out-of-band drift from declared pending changes |
| Clean plan | Provider reads unset values back as `{}`/`[]` (state has `null`), giving a false positive | Treat `null`, `{}` and `[]` as equal; regression test from the real plan |
| Scenario 1 | Agent MR plan failed: the flow's service account (Developer) cannot lock GitLab state | Plans run with `-lock=false`; apply still locks; jobs serialized by `resource_group` |
| Scenario 1 | Evidence included server bookkeeping (`etag`, revisions) and `last_modifier`, which published a personal email | Report only attributes the declared config manages; redact personal emails; regression test |
| Scenario 1 | `gcloud` stamps `client`/`client_version` on every change, causing recurring drift | `lifecycle.ignore_changes` for those two fields |
| Scenario 4 setup | Playbook had no precedence between revert and escalate | Escalate first; identity drift defined; a human decision via mention resumes the workflow |

## Sessions and evidence

| Scenario | Drift-check pipeline | Issue | Duo session(s) | MR | Apply + verify pipeline |
|---|---|---|---|---|---|
| 1 | 2941573449 | #3 | 9366562 | !1 | 2941636735 |
| 2 | 2941650151 | #4 | 9367692 | !2 | 2941694685 |
| 3 | 2941710498 | n/a | n/a | n/a | n/a |
| 4 | 2941717771 | #5 | 9368508 (escalate), 9368853 (human decision) | !3 | 2941760438 |
