#!/bin/sh
# Open (or update) a drift issue with the redacted evidence and start the Duo investigator flow.
# Runs in CI after detect-drift. Needs: DUO_FLOW_TOKEN (api scope), DRIFT_FLOW_NAME,
# DETECT_JOB_ID, DRIFT_DETECTED, OUT_OF_SYNC, evidence/drift-report.{md,json}.
set -eu

: "${DUO_FLOW_TOKEN:?DUO_FLOW_TOKEN (personal access token, api scope) is not set}"
: "${DRIFT_FLOW_NAME:?}"
: "${DETECT_JOB_ID:?}"

api="${CI_API_V4_URL}"
project="${CI_PROJECT_ID}"
auth="PRIVATE-TOKEN: ${DUO_FLOW_TOKEN}"
report_md=evidence/drift-report.md
report_json=evidence/drift-report.json
job_url="${CI_PROJECT_URL}/-/jobs/${DETECT_JOB_ID}"

gl() { curl --silent --show-error --fail-with-body --header "$auth" "$@"; }

if [ "${DRIFT_DETECTED:-false}" != "true" ]; then
  if [ "${OUT_OF_SYNC:-false}" = "true" ]; then
    echo "Live environment differs from main, but no out-of-band drift: unapplied changes on main."
    echo "Nothing to investigate. Run the manual apply job on the latest main pipeline."
  else
    echo "No drift: live environment matches the declared configuration."
  fi
  exit 0
fi

# One investigation at a time: if a drift issue is already open, add the new evidence to it.
existing=$(gl "${api}/projects/${project}/issues?labels=drift&state=opened&per_page=1" | jq -r '.[0].iid // empty')
if [ -n "$existing" ]; then
  body=$(printf 'Drift still present at %s ([detect-drift job](%s)). An investigation is already open; not starting another.\n\n%s' \
    "$(date -u +%Y-%m-%dT%H:%MZ)" "$job_url" "$(cat "$report_md")")
  gl --request POST "${api}/projects/${project}/issues/${existing}/notes" --data-urlencode "body=${body}" > /dev/null
  echo "Updated open drift issue #${existing}."
  exit 0
fi

summary=$(jq -r '[.drift[] | "\(.address) (\(.differences | map(.attribute) | join(", ")))"] | join("; ")' "$report_json")
title="Drift detected: $(printf '%s' "$summary" | cut -c1-200)"
description=$(cat <<EOF
Drift was detected by the scheduled \`detect-drift\` job. The Duo Drift Detective flow will investigate.

- **detect-drift job:** ${job_url} (job ID \`${DETECT_JOB_ID}\`)
- **Pipeline:** ${CI_PIPELINE_URL}
- **Declared configuration:** \`terraform/\` at \`${CI_COMMIT_SHORT_SHA}\`

$(cat "$report_md")

<details><summary>Structured evidence (JSON)</summary>

\`\`\`json
$(jq '{drift, planned_changes}' "$report_json")
\`\`\`

</details>
EOF
)

issue=$(gl --request POST "${api}/projects/${project}/issues" \
  --data-urlencode "title=${title}" \
  --data-urlencode "description=${description}" \
  --data-urlencode "labels=drift,drift::investigating")
iid=$(printf '%s' "$issue" | jq -r .iid)
echo "Opened drift issue #${iid}: $(printf '%s' "$issue" | jq -r .web_url)"

# Look up this project's configuration of the flow (the consumer ID the workflows API needs).
consumer=$(gl --request POST "${CI_API_GRAPHQL_URL}" --header "Content-Type: application/json" \
  --data "$(jq -n --arg p "gid://gitlab/Project/${project}" \
    '{query: "query($p: ProjectID!) { aiCatalogConfiguredItems(projectId: $p) { nodes { id enabled item { name } } } }", variables: {p: $p}}')" \
  | jq -r --arg name "$DRIFT_FLOW_NAME" \
    '.data.aiCatalogConfiguredItems.nodes[] | select(.item.name == $name and .enabled) | .id | split("/") | last' | head -1)
if [ -z "$consumer" ]; then
  echo "Flow '${DRIFT_FLOW_NAME}' is not enabled in this project (run scripts/publish_flow.sh)." >&2
  exit 1
fi

goal="Investigate drift issue #${iid} in project ${project}. The evidence was produced by detect-drift job ${DETECT_JOB_ID} (${job_url}); verify it against that job's log. Follow skills/drift-investigation/SKILL.md."
session=$(gl --request POST "${api}/ai/duo_workflows/workflows" --header "Content-Type: application/json" \
  --data "$(jq -n --arg project "$project" --argjson consumer "$consumer" --argjson iid "$iid" --arg goal "$goal" \
    '{project_id: $project, ai_catalog_item_consumer_id: $consumer, issue_id: $iid, goal: $goal,
      start_workflow: true, allow_agent_to_request_user: false, environment: "ambient"}')")
session_url=$(printf '%s' "$session" | jq -r .web_url)
echo "Started Duo flow session: ${session_url} (status $(printf '%s' "$session" | jq -r .status))"

gl --request POST "${api}/projects/${project}/issues/${iid}/notes" \
  --data-urlencode "body=Started Duo Drift Detective session: ${session_url}" > /dev/null
