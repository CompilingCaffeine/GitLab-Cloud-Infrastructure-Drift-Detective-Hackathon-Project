#!/bin/sh
# Close the loop after a verified apply on the default branch: if the applied commit came from a
# drift merge request ("Drift-Issue: #N" in its description), post the verification and close issue #N.
# Needs: DUO_FLOW_TOKEN, evidence/drift-report.json from the verify plan.
set -eu

: "${DUO_FLOW_TOKEN:?}"
api="${CI_API_V4_URL}"
project="${CI_PROJECT_ID}"
auth="PRIVATE-TOKEN: ${DUO_FLOW_TOKEN}"
gl() { curl --silent --show-error --fail-with-body --header "$auth" "$@"; }

mrs=$(gl "${api}/projects/${project}/repository/commits/${CI_COMMIT_SHA}/merge_requests")
iid=$(printf '%s' "$mrs" | jq -r '[.[] | select(.state == "merged") | (.description // "" | capture("Drift-Issue: #(?<n>[0-9]+)") | .n)?] | first // empty')
mr_url=$(printf '%s' "$mrs" | jq -r '[.[] | select(.state == "merged")][0].web_url // empty')

if [ -z "$iid" ]; then
  echo "Applied commit is not linked to a drift issue; nothing to close."
  exit 0
fi

in_sync=$(jq -r '(.drift_detected or .changes_pending) | not' evidence/drift-report.json)
if [ "$in_sync" != "true" ]; then
  echo "Verification did not confirm a clean state; leaving issue #${iid} open." >&2
  exit 1
fi

body=$(cat <<EOF
### Verified: drift resolved

- **Merge request:** ${mr_url}
- **Apply job:** ${CI_PROJECT_URL}/-/jobs/$(gl "${api}/projects/${project}/pipelines/${CI_PIPELINE_ID}/jobs?scope%5B%5D=success" | jq -r '.[] | select(.name == "apply") | .id' | head -1)
- **Verify job:** ${CI_JOB_URL}: a fresh plan reports no changes. The live environment matches \`terraform/\` at \`${CI_COMMIT_SHORT_SHA}\`.

Closing this issue.
EOF
)

gl --request POST "${api}/projects/${project}/issues/${iid}/notes" --data-urlencode "body=${body}" > /dev/null
gl --request PUT "${api}/projects/${project}/issues/${iid}" \
  --data-urlencode "state_event=close" \
  --data-urlencode "add_labels=drift::resolved" > /dev/null
echo "Closed drift issue #${iid}."
