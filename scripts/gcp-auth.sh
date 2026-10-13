#!/bin/sh
# Exchange the job's GitLab OIDC token for short-lived Google credentials.
# Sourced by CI jobs (so no `set -e` here: it would leak into the job shell).
# Requires: GCP_ID_TOKEN (id_tokens), GCP_WIF_PROVIDER, GCP_SA.

: "${GCP_ID_TOKEN:?id_tokens GCP_ID_TOKEN is not configured for this job}"
: "${GCP_WIF_PROVIDER:?}"
: "${GCP_SA:?}"

cred_dir="${CI_BUILDS_DIR:-/tmp}/.gcp-${CI_JOB_ID:-local}"
mkdir -p "$cred_dir"
chmod 700 "$cred_dir"
printf '%s' "$GCP_ID_TOKEN" > "$cred_dir/oidc.jwt"

jq -n \
  --arg audience "//iam.googleapis.com/${GCP_WIF_PROVIDER}" \
  --arg token_file "$cred_dir/oidc.jwt" \
  --arg sa_url "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${GCP_SA}:generateAccessToken" \
  '{
    type: "external_account",
    audience: $audience,
    subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
    token_url: "https://sts.googleapis.com/v1/token",
    credential_source: { file: $token_file },
    service_account_impersonation_url: $sa_url
  }' > "$cred_dir/credentials.json"

export GOOGLE_APPLICATION_CREDENTIALS="$cred_dir/credentials.json"
echo "GCP: using ${GCP_SA} via workload identity federation"
