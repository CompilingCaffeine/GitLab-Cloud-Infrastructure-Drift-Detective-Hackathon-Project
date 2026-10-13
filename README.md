# Cloud Infrastructure Drift Detective

**A GitLab Duo Agent Platform flow that finds infrastructure drift, works out what it means, and
proposes the fix as a merge request. A human approves every change to the cloud.**

Someone changes production in the cloud console. Terraform never finds out. Weeks later a routine
`apply` silently reverts it, or an exposed service sits unnoticed. Drift Detective closes that gap
inside GitLab: a scheduled pipeline detects the drift, a Duo flow investigates it against real
pipeline evidence, decides whether to **revert**, **adopt**, or **escalate**, and opens a merge
request. CI enforces guardrails, a human merges and applies, and the pipeline verifies the result
and closes the issue.

- **Autonomy level:** Supervised. Agents investigate and prepare the fix on their own. A human approves the outcome.
- **Live deployment (Google Cloud Run):** https://drift-demo-web-ut5yuq6zba-uc.a.run.app
- **Evidence:** [pipelines](https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/pipelines),
  drift issues [#3](https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/issues/3),
  [#4](https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/issues/4),
  [#5](https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/issues/5),
  agent merge requests [!1](https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/merge_requests/1),
  [!2](https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/merge_requests/2),
  [!3](https://gitlab.com/gitlab-ai-hackathon/transcend-october-2026/33443675/showcase/-/merge_requests/3),
  and the [measured evaluation](docs/evaluation.md).

## How it works

```mermaid
flowchart TB
  OOB["Out-of-band change<br/>console or gcloud"] -.-> GCP

  subgraph GCP["Google Cloud Run"]
    direction LR
    WEB["drift-demo-web<br/>public"]
    INT["drift-demo-internal<br/>auth required"]
  end

  subgraph S1["1 Detect: GitLab CI"]
    direction LR
    SCHED["Schedule<br/>every 6 h"] --> DET["detect-drift<br/>tofu plan, read-only identity"]
    DET -->|"drift found"| INV["investigate<br/>evidence issue,<br/>start flow via API"]
  end

  subgraph S2["2 Investigate: GitLab Duo flow"]
    direction LR
    I["investigator agent<br/>check job log, risk, decide"] -->|"revert / adopt"| R["remediator agent<br/>opens merge request"]
    I -->|"escalate"| ESC["comment only,<br/>no merge request"]
  end

  subgraph S3["3 Approve: human"]
    direction LR
    MRCI["MR pipeline<br/>fmt, validate, tests,<br/>plan, policy guardrails"] --> H1{{"review and merge"}}
    H2{{"reply: decision revert / adopt"}}
  end

  subgraph S4["4 Apply and verify: GitLab CI"]
    direction LR
    APPLY["manual apply<br/>main-only identity"] --> VER["verify<br/>plan must be empty"] --> CLOSE["close issue<br/>with evidence links"]
  end

  DET -.-> GCP
  INV --> I
  R --> MRCI
  ESC --> H2
  H2 -->|"mention trigger"| I
  H1 --> APPLY
  APPLY -.-> GCP
```

1. **Detect.** A pipeline schedule runs `tofu plan -detailed-exitcode` against the live environment
   with a read-only identity. `scripts/summarize_plan.sh` turns the plan into evidence. It separates
   out-of-band drift from unapplied code, keeps only attributes the configuration manages, and redacts
   sensitive values and personal emails. The full JSON plan never leaves the job.
2. **Hand off.** If there is real drift, `scripts/start_drift_flow.sh` opens one deduplicated issue
   with the evidence and starts the flow through `POST /api/v4/ai/duo_workflows/workflows`.
3. **Investigate.** The investigator agent follows [`skills/drift-investigation/SKILL.md`](skills/drift-investigation/SKILL.md).
   It cross-checks the issue against the `detect-drift` **job log**, reads the declared Terraform,
   classifies risk, labels every guess as a hypothesis, and posts one structured report.
4. **Decide.** A conditional router sends `revert` and `adopt` to the remediator agent. `escalate` ends
   the flow with a comment and no merge request.
5. **Propose.** The remediator opens one merge request from `duo/fix/drift-issue-N`. Revert MRs only add
   an incident record (the code is already right). Adopt MRs change only the drifted attributes.
6. **Validate.** The MR pipeline runs `fmt`, `validate`, the test suite, and a plan with
   [`scripts/policy_check.sh`](scripts/policy_check.sh). The guardrails hold even if the agent is wrong.
7. **Approve and apply.** A human merges and clicks the manual `apply` job on `main`.
8. **Verify and close.** `verify` re-plans and must see **no changes**. It then follows the merged MR's
   `Drift-Issue: #N` trailer, posts links to the evidence, and closes the issue.

If the agent escalates, the human replies on the issue with `@ai-drift-detective-investigator-gitlab-ai-hackathon decision: revert`
(or `adopt`). The mention trigger restarts the flow with that decision, and the same loop finishes the job.

## How the agent decides

| Decision | When | Merge request |
|---|---|---|
| **escalate** | Checked first. Evidence missing or contradictory, the plan would `delete` or `replace`, a runtime identity changed, or the agent is unsure | None. Both options are laid out for a human |
| **revert** | Any other High-risk drift (authentication weakened, invokers changed), or anything it cannot justify adopting | Incident record only; apply restores the declared state |
| **adopt** | Low risk (or Medium with no security impact), within every guardrail, and reverting would plausibly reduce availability | Smallest `terraform/` edit plus incident record |

Guardrails, enforced in CI on every plan: the internal service must require authentication, no
`allUsers`/`allAuthenticatedUsers` invokers, `max_instance_count` at most 5, and the `managed-by = terraform`
label on every service.

## Results

Measured on the live environment. The full timings, caveats, and defects found are in [docs/evaluation.md](docs/evaluation.md).

| Scenario | Agent decision | Detection → MR or escalation | Apply → verified and closed |
|---|---|---|---|
| Capacity raised 2 → 4 with gcloud | adopt (Low) | 2 min 33 s | 46 s |
| Internal API authentication disabled | revert (High) | 2 min 23 s | 68 s |
| No drift | no issue, no agent run | 46 s (detection only) | n/a |
| Internal API identity swapped | escalate (High), then revert on human decision | 2 min 16 s | 63 s |

Detection was triggered by hand right after each change. On the 6-hour schedule, detection itself can take up to 6 hours.

## GitLab features used

- **Duo Agent Platform:** a custom flow with two agents and a conditional router, kept as YAML in
  [`flows/`](flows) and published by [`scripts/publish_flow.sh`](scripts/publish_flow.sh) through the
  AI Catalog GraphQL API. It is started by the workflows REST API, and resumed by a **mention trigger**.
- **Project skill:** [`skills/drift-investigation/SKILL.md`](skills/drift-investigation/SKILL.md) is the
  agent's playbook, versioned and reviewed like code.
- **CI/CD:** pipeline schedules, a manual job as the approval gate, environments, `resource_group`
  serialization, dotenv artifacts between jobs, the Terraform MR widget report, and **OIDC `id_tokens`**.
- **GitLab-managed OpenTofu state** and the official `gitlab-opentofu` image from the
  [OpenTofu CI/CD component](https://gitlab.com/components/opentofu).
- **Issues and merge requests** as the audit trail: scoped labels (`drift::investigating` → `drift::resolved`),
  and closing driven by a merge-request trailer.

## Security model

**Enforced by design.** These hold regardless of what the model does.

- **No long-lived cloud keys.** CI exchanges its OIDC token for short-lived Google credentials
  (workload identity federation, which rejects tokens from any other GitLab project).
- **Two identities.** `drift-plan` (`roles/run.viewer`) is used for detection and every plan.
  `drift-apply` (`roles/run.admin`) can only be obtained by pipelines on `main`. In this pipeline,
  only the manual `apply` job requests it.
- **The agent cannot change cloud infrastructure.** The flow never receives cloud credentials, and it has
  no tools to merge, approve, or run pipelines.
- **Guardrails don't depend on the agent.** `policy_check.sh` fails any plan that breaks a guardrail,
  so an unsafe "adopt" cannot pass CI.
- **Published evidence is redacted.** A script masks sensitive values and removes personal emails before
  anything reaches an issue. The raw JSON plan never becomes an artifact. The binary plan cache that
  `apply` needs is an artifact, restricted to project members (`access: developer`).

**Required by the playbook.** The agent followed these in every evaluation run, but they are
instructions in [`SKILL.md`](skills/drift-investigation/SKILL.md), not technical controls.

- Work only from tool output (the issue, the job log, the repository), and label every guess as a hypothesis.
- Escalate on identity changes, delete or replace plans, contradictory evidence, or uncertainty.
- Open at most one merge request per incident, touching only `terraform/` and `drift/incidents/`.
- Act on a human's decision only when it uses the exact wording `decision: revert` or `decision: adopt`.

**Known limits** (from the hackathon's Developer role, documented rather than hidden):
- `main` is not protected against Developer pushes. Two consequences:
  - "main only" for the apply identity is weaker than in a real setup.
  - The flow's service account could technically commit directly to `main`. Nothing reaches the cloud
    without a human running `apply`.

  With Maintainer access, protect `main` and the `demo` environment, and require merge request approval.
- The flow is started with a personal access token (`DUO_FLOW_TOKEN`, `api` scope) in a masked, unprotected
  CI variable. GitLab triggers ignore bot users, so a human token is needed to start flows from CI.
- Plans run with `-lock=false`, because the flow's service account can read but not lock state. Apply
  still locks, and `resource_group` serializes every job that touches the state.

## Repository layout

```text
.gitlab-ci.yml                  validate, plan, apply, verify, drift, investigate
bootstrap/                      one-time: workload identity federation and service accounts
terraform/                      the managed environment (two Cloud Run services and an IAM binding)
flows/drift-investigator.yml    the Duo custom flow (investigator and remediator)
skills/drift-investigation/     the agent's playbook
scripts/                        GCP auth, evidence, policy, flow start, issue closing, flow publishing
tests/                          tests for the evidence and policy scripts (real plan fixture)
drift/incidents/                incident records committed by the agent's merge requests
docs/                           measured evaluation, architecture diagram (PNG)
```

## Run it yourself

Requires a GitLab project with Duo Agent Platform (custom flows enabled), a Google Cloud project with
billing, and `tofu` (or `terraform`), `gcloud`, `glab`, and `jq` installed.

1. **Point it at your projects.** Replace `drift-detective-2026`, the project number, and the GitLab path
   in `bootstrap/variables.tf`, `terraform/variables.tf`, and the `variables` and `id_tokens` in `.gitlab-ci.yml`.
2. **Bootstrap Google Cloud** (identities only, local state):
   ```sh
   gcloud services enable run.googleapis.com iam.googleapis.com iamcredentials.googleapis.com \
     sts.googleapis.com cloudresourcemanager.googleapis.com
   cd bootstrap && tofu init && tofu apply
   ```
3. **Add the CI variable** `DUO_FLOW_TOKEN`: a personal access token with `api` scope, masked.
4. **Publish and enable the flow:**
   ```sh
   GITLAB_TOKEN=$(glab config get token) GITLAB_PROJECT_ID=<id> \
     scripts/publish_flow.sh drift-detective-investigator flows/drift-investigator.yml "Drift investigator"
   ```
5. **Deploy:** push to `main`, then run the manual `apply` job. `verify` should report no changes.
6. **Schedule detection:** create a pipeline schedule on `main` (for example `0 */6 * * *`). Scheduled
   pipelines run only `detect-drift` and `investigate`.

**Try a scenario**, then click **Run** on the schedule:

```sh
gcloud run services update drift-demo-web --region us-central1 --max-instances 4      # expect adopt
gcloud run services update drift-demo-internal --region us-central1 --no-invoker-iam-check  # expect revert
gcloud run services update drift-demo-internal --region us-central1 \
  --service-account drift-demo-web@<project>.iam.gserviceaccount.com                  # expect escalate
```

Run the tests locally with `tests/run_tests.sh` (needs only `sh` and `jq`).

## Cost and teardown

Both services scale to zero, so the environment costs close to nothing at idle. A $10 budget alert is
set on the project. Each agent investigation uses GitLab Credits, and
runs with no drift start no agent.

To remove everything: delete the pipeline schedule, delete the `demo` Terraform state
(**Operate → Terraform states**), remove the flow from the AI Catalog, and run
`gcloud projects delete drift-detective-2026`.

## License

[MIT](LICENSE)
