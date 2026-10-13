#!/bin/sh
# Enforce drift guardrails on the state a plan would produce.
# Usage: policy_check.sh plan.json   (full `tofu show -json` output)
# Exits 1 and lists violations if any guardrail is broken.
set -eu

plan="${1:?usage: policy_check.sh plan.json}"
max_instances=5

violations=$(jq -r --argjson max "$max_instances" '
  [ .planned_values.root_module.resources[]? ] as $res
  | ($res | map(select(.type == "google_cloud_run_v2_service"))) as $services
  | [
      ($services[] | select(.values.name == "drift-demo-internal" and .values.invoker_iam_disabled != false)
        | "\(.address): internal service must require authentication (invoker_iam_disabled = false)"),

      ($res[] | select(.type | test("_iam_(binding|member|policy)$"))
        | . as $r
        | ([.values.members[]?, .values.member?] | map(select(. != null)))[]
        | select(. == "allUsers" or . == "allAuthenticatedUsers")
        | "\($r.address): public principal \(.) is not allowed"),

      ($services[] | select((.values.template[0].scaling[0].max_instance_count // 0) > $max)
        | "\(.address): max_instance_count \(.values.template[0].scaling[0].max_instance_count) exceeds \($max)"),

      ($services[] | select(.values.labels["managed-by"] != "terraform")
        | "\(.address): label managed-by = terraform is required")
    ]
  | .[]
' "$plan")

if [ -n "$violations" ]; then
  echo "Policy check FAILED:"
  echo "$violations" | sed 's/^/  - /'
  exit 1
fi

echo "Policy check passed: all drift guardrails hold for the planned state."
