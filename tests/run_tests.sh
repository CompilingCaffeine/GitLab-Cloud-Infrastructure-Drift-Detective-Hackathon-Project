#!/bin/sh
# Tests for the evidence and policy scripts. Needs only sh and jq.
# Usage: tests/run_tests.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
fixture="$root/tests/fixtures/plan-create.json"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

# Build a variant of the fixture plan with a jq edit.
variant() { jq "$2" "$fixture" > "$work/$1.json"; echo "$work/$1.json"; }

expect_policy() { # name expected_exit plan [expected_text]
  out=$("$root/scripts/policy_check.sh" "$3" 2>&1); code=$?
  if [ "$code" -ne "$2" ]; then fail "$1 (exit $code, want $2): $out"; return; fi
  if [ -n "${4:-}" ] && ! printf '%s' "$out" | grep -q "$4"; then fail "$1 (missing '$4'): $out"; return; fi
  pass "$1"
}

internal='.planned_values.root_module.resources |= map(if .address == "google_cloud_run_v2_service.internal"'
web='.planned_values.root_module.resources |= map(if .address == "google_cloud_run_v2_service.web"'
binding='.planned_values.root_module.resources |= map(if .address == "google_cloud_run_v2_service_iam_binding.internal_invoker"'

# --- policy_check.sh ---
expect_policy "policy: declared configuration passes" 0 "$fixture" "passed"
expect_policy "policy: internal service made public fails" 1 \
  "$(variant public "$internal then .values.invoker_iam_disabled = true else . end)")" "must require authentication"
expect_policy "policy: allUsers invoker fails" 1 \
  "$(variant allusers "$binding then .values.members += [\"allUsers\"] else . end)")" "allUsers"
expect_policy "policy: scaling above guardrail fails" 1 \
  "$(variant scale "$web then .values.template[0].scaling[0].max_instance_count = 10 else . end)")" "exceeds 5"
expect_policy "policy: scaling within guardrail passes" 0 \
  "$(variant scale-ok "$web then .values.template[0].scaling[0].max_instance_count = 4 else . end)")"
expect_policy "policy: missing managed-by label fails" 1 \
  "$(variant label "$web then .values.labels |= del(.[\"managed-by\"]) else . end)")" "managed-by"
expect_policy "policy: public web service is allowed" 0 "$fixture"

# --- security_gate.sh ---
report() { # name severity...
  f="$work/$1.json"; shift
  printf '%s\n' "$@" | jq -R 'select(length > 0) | {severity: ., name: "finding", location: {file: "x.tf", start_line: 1}}' \
    | jq -s '{scan: {scanner: {name: "test"}}, vulnerabilities: .}' > "$f"
  echo "$f"
}
expect_gate() { # name expected_exit report...
  name=$1; want=$2; shift 2
  out=$("$root/scripts/security_gate.sh" "$@" 2>&1); code=$?
  [ "$code" -eq "$want" ] && pass "$name" || fail "$name (exit $code, want $want): $out"
}
expect_gate "gate: info and medium findings pass" 0 "$(report low Info Medium)" "$(report none)"
expect_gate "gate: a high finding fails" 1 "$(report clean Info)" "$(report high High)"
expect_gate "gate: a critical finding fails" 1 "$(report critical Critical)"
expect_gate "gate: a missing report fails" 1 "$work/does-not-exist.json"

# --- summarize_plan.sh ---
drift_plan=$(variant drift '
  .resource_drift = [{
    address: "google_cloud_run_v2_service.internal", type: "google_cloud_run_v2_service", name: "internal",
    change: {actions: ["update"],
      before: {invoker_iam_disabled: false, template: [{containers: [{env: [{name: "API_KEY", value: "old-secret"}]}]}]},
      after:  {invoker_iam_disabled: true,  template: [{containers: [{env: [{name: "API_KEY", value: "new-secret"}]}]}]},
      before_sensitive: {template: [{containers: [{env: [{value: true}]}]}]},
      after_sensitive:  {template: [{containers: [{env: [{value: true}]}]}]}}
  }]
  | .resource_changes = [.resource_drift[0] | .change.actions = ["update"]
      | .change.before.invoker_iam_disabled = true | .change.after.invoker_iam_disabled = false]')

"$root/scripts/summarize_plan.sh" "$drift_plan" "$work/out-drift" > /dev/null
r="$work/out-drift/drift-report.json"
[ "$(jq -r .drift_detected "$r")" = true ] && pass "summary: out-of-band drift detected" || fail "summary: drift flag"
[ "$(jq -r '.drift[0].differences | map(.attribute) | index("invoker_iam_disabled") != null' "$r")" = true ] \
  && pass "summary: drifted attribute listed" || fail "summary: drifted attribute missing"
if grep -q secret "$r" "$work/out-drift/drift-report.md"; then fail "summary: sensitive value leaked"
else pass "summary: sensitive values redacted"; fi
[ "$(grep -c '^## Drift report' "$work/out-drift/drift-report.md")" -eq 1 ] \
  && pass "summary: report rendered once" || fail "summary: report duplicated"

"$root/scripts/summarize_plan.sh" "$fixture" "$work/out-create" > /dev/null
r="$work/out-create/drift-report.json"
[ "$(jq -r '[.drift_detected, .changes_pending] | join(",")' "$r")" = "false,true" ] \
  && pass "summary: first deploy is pending changes, not drift" || fail "summary: create misclassified"

# Seen on real Cloud Run plans: state has null, the API returns {} or []. That is not drift.
noise_plan=$(variant noise '
  .resource_drift = [{
    address: "google_cloud_run_v2_service.web", type: "google_cloud_run_v2_service", name: "web",
    change: {actions: ["update"],
      before: {annotations: null, custom_audiences: null, template: [{labels: null, containers: [{args: null}]}]},
      after:  {annotations: {},   custom_audiences: [],   template: [{labels: {},   containers: [{args: []}]}]}}
  }]
  | .resource_changes = []')
"$root/scripts/summarize_plan.sh" "$noise_plan" "$work/out-noise" > /dev/null
[ "$(jq -r '[.drift_detected, (.drift | length)] | map(tostring) | join(",")' "$work/out-noise/drift-report.json")" = "false,0" ] \
  && pass "summary: null vs empty read-back is not drift" || fail "summary: null/empty noise reported as drift"

# Seen on a real gcloud change: the managed attribute changes alongside server bookkeeping and the
# email of the person who made it. Only the managed attribute is drift; no email may be published.
real_plan=$(variant real-gcloud '
  .resource_drift = [{
    address: "google_cloud_run_v2_service.web", type: "google_cloud_run_v2_service", name: "web",
    change: {actions: ["update"],
      before: {etag: "\"a\"", generation: "1", last_modifier: "drift-apply@p.iam.gserviceaccount.com", template: [{scaling: [{max_instance_count: 2}]}]},
      after:  {etag: "\"b\"", generation: "2", last_modifier: "someone@example.com", template: [{scaling: [{max_instance_count: 4}]}]}}
  }]
  | .resource_changes = [{
    address: "google_cloud_run_v2_service.web", type: "google_cloud_run_v2_service", name: "web",
    change: {actions: ["update"],
      before: {last_modifier: "someone@example.com", template: [{scaling: [{max_instance_count: 4}]}]},
      after:  {last_modifier: "someone@example.com", template: [{scaling: [{max_instance_count: 2}]}]}}
  }]')
"$root/scripts/summarize_plan.sh" "$real_plan" "$work/out-real" > /dev/null
[ "$(jq -r '.drift[0].differences | map(.attribute) | join(",")' "$work/out-real/drift-report.json")" = "template.0.scaling.0.max_instance_count" ] \
  && pass "summary: drift limited to attributes the config manages" || fail "summary: bookkeeping reported as drift"
if grep -q "someone@example.com" "$work/out-real/drift-report.json" "$work/out-real/drift-report.md"; then
  fail "summary: personal email published"
else pass "summary: personal emails never published"; fi

echo '{}' > "$work/empty.json"
"$root/scripts/summarize_plan.sh" "$work/empty.json" "$work/out-empty" > /dev/null
[ "$(jq -r '[.drift_detected, .changes_pending] | join(",")' "$work/out-empty/drift-report.json")" = "false,false" ] \
  && pass "summary: empty plan is in sync" || fail "summary: empty plan"

echo
if [ "$failures" -gt 0 ]; then echo "$failures test(s) failed"; exit 1; fi
echo "All tests passed"
