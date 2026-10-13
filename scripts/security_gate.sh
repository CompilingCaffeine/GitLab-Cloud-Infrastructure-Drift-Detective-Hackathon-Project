#!/bin/sh
# Fail the pipeline on Critical or High findings from GitLab security scanner reports.
# The scanners themselves are report-only (allow_failure), so this job is the actual gate.
# Usage: security_gate.sh report.json [report.json ...]
# To accept a specific finding, suppress it next to the code with a reason
# (KICS: `# kics-scan ignore-line`), so the exception is reviewed like any other change.
set -eu

[ "$#" -gt 0 ] || { echo "usage: security_gate.sh report.json [...]" >&2; exit 2; }

blocking=0
for report in "$@"; do
  if [ ! -f "$report" ]; then
    echo "Missing scanner report: $report (did the scanner job run?)" >&2
    exit 1
  fi
  scanner=$(jq -r '.scan.scanner.name // .scan.analyzer.name // "scanner"' "$report")
  echo "== ${scanner}: $(jq '.vulnerabilities | length' "$report") finding(s)"
  jq -r '.vulnerabilities[] | "  [\(.severity)] \(.name) at \(.location.file // "?"):\(.location.start_line // "?")"' "$report"
  n=$(jq '[.vulnerabilities[] | select(.severity == "Critical" or .severity == "High")] | length' "$report")
  blocking=$((blocking + n))
done

if [ "$blocking" -gt 0 ]; then
  echo "Security gate FAILED: ${blocking} Critical/High finding(s)."
  exit 1
fi
echo "Security gate passed: no Critical or High findings."
