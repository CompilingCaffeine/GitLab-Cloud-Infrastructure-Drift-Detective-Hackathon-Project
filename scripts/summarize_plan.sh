#!/bin/sh
# Summarize an OpenTofu/Terraform JSON plan into machine- and human-readable drift evidence.
# Usage: summarize_plan.sh plan.json out_dir
#   out_dir/drift-report.json  structured evidence (consumed by the Duo flow)
#   out_dir/drift-report.md    the same evidence for humans (issue body, job log)
set -eu

plan="${1:?usage: summarize_plan.sh plan.json out_dir}"
out="${2:?usage: summarize_plan.sh plan.json out_dir}"
mkdir -p "$out"

# For each entry, list the leaf attributes whose values differ, with before/after.
# resource_drift: changes made OUTSIDE OpenTofu (before = last applied state, after = real world).
# resource_changes: what applying the declared config would do to the real world now.
jq '
  # Sensitive values appear in clear text in JSON plans; the *_sensitive masks say which.
  def masked($mask; $p):
    if ($mask | type) == "object" or ($mask | type) == "array"
    then ([$p[:range(0; ($p | length) + 1)]] | any(. as $q | ($mask | try getpath($q) catch null) == true))
    else $mask == true end;
  def shown($v; $mask; $p): if masked($mask; $p) then "(sensitive)" else ($v | getpath($p)) end;

  def leafdiff:
    (.before // {}) as $b | (.after // {}) as $a
    | (.before_sensitive // false) as $bs | (.after_sensitive // false) as $as
    | [ ($b, $a) | paths(type != "object" and type != "array") ]
    | unique
    | map(. as $p | select(($b | getpath($p)) != ($a | getpath($p))))
    | map(. as $p | {
        attribute: ($p | map(tostring) | join(".")),
        before: shown($b; $bs; $p),
        after: shown($a; $as; $p)
      });

  def entry:
    {
      address,
      type,
      name,
      actions: .change.actions,
      differences: (.change | leafdiff)
    };

  {
    generated_at: (now | todate),
    pipeline_url: env.CI_PIPELINE_URL,
    job_url: env.CI_JOB_URL,
    commit_sha: env.CI_COMMIT_SHA,
    drift: [ .resource_drift[]? | entry ],
    planned_changes: [ .resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | entry ]
  }
  # drift: someone changed real infrastructure outside OpenTofu.
  # pending: the declared config differs from reality (drift to revert, or unapplied code).
  | .drift_detected = ((.drift | length) > 0)
  | .changes_pending = ((.planned_changes | length) > 0)
' "$plan" > "$out/drift-report.json"

jq -r '
  def fmt: if . == null then "(unset)" else tojson end;
  def table(rows):
    if (rows | length) == 0 then "_None._\n"
    else
      [rows[] |
        "#### `\(.address)` (\(.actions | join(", ")))\n\n" +
        "| Attribute | Before | After |\n|---|---|---|\n" +
        ([.differences[] | "| `\(.attribute)` | `\(.before | fmt)` | `\(.after | fmt)` |"] | join("\n")) +
        "\n"] | join("\n")
    end;

  "## Drift report\n\n" +
  "- **Out-of-band drift detected:** \(.drift_detected)\n" +
  "- **Declared changes pending:** \(.changes_pending)\n" +
  "- **Pipeline:** \(.pipeline_url // "local")\n" +
  "- **Job:** \(.job_url // "local")\n" +
  "- **Commit:** `\(.commit_sha // "local")`\n\n" +
  "### Changes made outside OpenTofu (state vs. real world)\n\n" + table(.drift) + "\n" +
  "### Changes the declared configuration would make now\n\n" + table(.planned_changes)
' "$out/drift-report.json" > "$out/drift-report.md"

cat "$out/drift-report.md"
