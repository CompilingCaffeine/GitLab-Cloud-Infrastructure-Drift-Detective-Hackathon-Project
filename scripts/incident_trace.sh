#!/bin/sh
# Build one OpenTelemetry trace for a drift incident from GitLab's own records and send it over
# OTLP/HTTP (JSON). Every span uses real timestamps: CI jobs come from the jobs API; agent and human
# stages are reconstructed from issue, comment, and merge request times (marked reconstructed=true).
#
# Usage: incident_trace.sh <issue iid>
# Env:   GITLAB_API (default $CI_API_V4_URL), PROJECT_ID (default $CI_PROJECT_ID),
#        GITLAB_AUTH_HEADER (e.g. "PRIVATE-TOKEN: ..." or "Authorization: Bearer ..."),
#        OTEL_EXPORTER_OTLP_ENDPOINT (unset = print the payload instead of sending),
#        GITLAB_OBSERVABILITY_TOKEN (optional bearer token for the OTLP endpoint).
set -eu

iid="${1:?usage: incident_trace.sh <issue iid>}"
api="${GITLAB_API:-${CI_API_V4_URL:?}}"
project="${PROJECT_ID:-${CI_PROJECT_ID:?}}"
: "${GITLAB_AUTH_HEADER:?}"
gl() { curl --silent --show-error --fail-with-body --header "$GITLAB_AUTH_HEADER" "$api/projects/$project$1"; }

issue=$(gl "/issues/$iid")
notes=$(gl "/issues/$iid/notes?sort=asc&per_page=100")
detect_job_id=$(printf '%s' "$issue" | jq -r '.description | capture("job ID `(?<id>[0-9]+)`").id')
detect=$(gl "/jobs/$detect_job_id")
investigate=$(gl "/pipelines/$(printf '%s' "$detect" | jq -r .pipeline.id)/jobs" | jq '[.[] | select(.name == "investigate")][0]')
mr=$(gl "/merge_requests?state=all&per_page=100" | jq --arg t "Drift-Issue: #$iid" '[.[] | select((.description // "") | contains($t))] | sort_by(.created_at) | last // empty')
if [ -n "$mr" ] && [ "$(printf '%s' "$mr" | jq -r .merge_commit_sha)" != null ]; then
  sha=$(printf '%s' "$mr" | jq -r .merge_commit_sha)
  # The push pipeline for the merge commit runs apply and verify (schedules may share the SHA).
  pipe=$(gl "/pipelines?sha=$sha&source=push&per_page=1" | jq -r '.[0].id')
  jobs=$(gl "/pipelines/$pipe/jobs")
else
  jobs='[]'
fi

# Assemble span records {key, parent, name, start, end, attrs} from the collected JSON.
spans=$(jq -n \
  --argjson issue "$issue" --argjson notes "$notes" --argjson detect "$detect" \
  --argjson investigate "$investigate" --argjson mr "${mr:-null}" --argjson jobs "$jobs" '
  def job($n): ($jobs | map(select(.name == $n)) | .[0]);
  def agent_reports: $notes | map(select((.author.username | startswith("ai-")) and (.body | startswith("## Drift investigation"))));
  def human_decisions: $notes | map(select((.author.username | startswith("ai-") | not) and (.system | not) and (.body | test("@ai-"))));
  def decision($n): $n.body | capture("\\*\\*Decision:\\*\\* (?<d>[a-z]+)").d;
  def risk($n): $n.body | capture("\\*\\*Risk:\\*\\* (?<r>[A-Za-z]+)").r;
  (agent_reports) as $reports | (human_decisions) as $humans
  | ($reports | last) as $final
  | [
      {key: "detect", name: "detect-drift (tofu plan)", start: $detect.started_at, end: $detect.finished_at,
       attrs: {"cicd.job.url": $detect.web_url}},
      ($investigate | select(. != null) | {key: "investigate", name: "investigate (evidence issue, start flow)",
       start: .started_at, end: .finished_at, attrs: {"cicd.job.url": .web_url}}),
      ($reports[0] | select(. != null) | {key: "agent1", name: "agent investigation: \(decision(.))",
       start: $issue.created_at, end: .created_at, reconstructed: true,
       attrs: {"drift.decision": decision(.), "drift.risk": risk(.)}}),
      (if ($humans | length) > 0 and ($reports | length) > 1 then
        {key: "human_decision", name: "human decision (mention)", start: $reports[0].created_at,
         end: $humans[0].created_at, reconstructed: true, attrs: {}},
        {key: "agent2", name: "agent acts on decision: \(decision($final))", start: $humans[0].created_at,
         end: $final.created_at, reconstructed: true,
         attrs: {"drift.decision": decision($final), "drift.risk": risk($final)}}
      else empty end),
      ($mr | select(. != null) | {key: "remediate", name: "agent opens merge request",
       start: $final.created_at, end: .created_at, reconstructed: true, attrs: {"vcs.change.url": .web_url}}),
      ($mr | select(. != null and .merged_at != null) | {key: "review", name: "human review and merge",
       start: .created_at, end: .merged_at, reconstructed: true, attrs: {}}),
      (job("apply") | select(. != null and .started_at != null) | {key: "apply", name: "apply (human-triggered)",
       start: .started_at, end: .finished_at, attrs: {"cicd.job.url": .web_url}}),
      (job("verify") | select(. != null and .started_at != null) | {key: "verify", name: "verify and close issue",
       start: .started_at, end: (.finished_at // (now | todate)), attrs: {"cicd.job.url": .web_url}})
    ]
  | map(select(.start != null and .end != null))
  | . as $children
  | [{key: "root", name: "drift incident #\($issue.iid)", start: $detect.started_at,
      end: ($issue.closed_at // ($children | map(.end) | max)),
      attrs: {"drift.issue.url": $issue.web_url, "drift.decision": (if $final then decision($final) else "none" end),
              "drift.risk": (if $final then risk($final) else "none" end),
              "drift.escalated": (($reports | length) > 1), "drift.resolved": ($issue.state == "closed")}}]
    + ($children | map(.parent = "root"))')

# Deterministic IDs: re-sending an incident reuses its trace ID.
hex() { printf '%s' "$1" | sha256sum | cut -c1-"$2"; }
trace_id=$(hex "drift-detective/$project/issue/$iid" 32)
ids=$(printf '%s' "$spans" | jq -r '.[].key' | while read -r k; do printf '{"key":"%s","id":"%s"}\n' "$k" "$(hex "$trace_id/$k" 16)"; done | jq -s 'map({(.key): .id}) | add')

payload=$(jq -n --argjson spans "$spans" --argjson ids "$ids" --arg trace "$trace_id" --arg project "$project" '
  # ISO-8601 to nanoseconds as a decimal string (no float rounding).
  def ns: sub("\\+00:00$"; "Z") | capture("^(?<d>[^.Z]+)(\\.(?<f>[0-9]+))?Z$") as $c
    | (($c.d + "Z") | fromdateiso8601 | tostring) + ((($c.f // "") + "000000000")[0:9]);
  def attr: to_entries | map({key, value: (if (.value | type) == "boolean" then {boolValue: .value} else {stringValue: (.value | tostring)} end)});
  {resourceSpans: [{
    resource: {attributes: ({"service.name": "drift-detective", "gitlab.project.id": $project} | attr)},
    scopeSpans: [{scope: {name: "drift-detective/incident_trace.sh"}, spans: [
      $spans[] | {
        traceId: $trace, spanId: $ids[.key],
        parentSpanId: (if .parent then $ids[.parent] else "" end),
        name, kind: 1, startTimeUnixNano: (.start | ns), endTimeUnixNano: (.end | ns),
        attributes: ((.attrs + (if .reconstructed then {"drift.reconstructed": true} else {} end)) | attr),
        status: {code: 1}
      }]}]}]}')

if [ -z "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
  printf '%s\n' "$payload"
  exit 0
fi

endpoint="${OTEL_EXPORTER_OTLP_ENDPOINT%/}"
case "$endpoint" in */v1/traces) ;; *) endpoint="$endpoint/v1/traces" ;; esac
set -- --silent --show-error --fail-with-body --header "Content-Type: application/json"
[ -n "${GITLAB_OBSERVABILITY_TOKEN:-}" ] && set -- "$@" --header "Authorization: Bearer ${GITLAB_OBSERVABILITY_TOKEN}"
printf '%s' "$payload" | curl "$@" --data-binary @- "$endpoint" > /dev/null
echo "Sent trace ${trace_id} for drift incident #${iid} ($(printf '%s' "$spans" | jq length) spans)."
