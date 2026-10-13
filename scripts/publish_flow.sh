#!/bin/sh
# Create or update a custom flow in the GitLab AI Catalog from a YAML file in this repo,
# then make sure it is enabled in the project. Idempotent.
#
# Usage: GITLAB_TOKEN=... scripts/publish_flow.sh <flow-name> <flow.yml> "<description>"
#   GITLAB_TOKEN: personal access token (api scope) or OAuth token (`glab config get token`).
#   GITLAB_PROJECT_ID defaults to the hackathon project.
set -eu

name="${1:?usage: publish_flow.sh <flow-name> <flow.yml> <description>}"
file="${2:?usage: publish_flow.sh <flow-name> <flow.yml> <description>}"
description="${3:?usage: publish_flow.sh <flow-name> <flow.yml> <description>}"
: "${GITLAB_TOKEN:?set GITLAB_TOKEN}"
project_id="${GITLAB_PROJECT_ID:-87486117}"
graphql="${GITLAB_GRAPHQL_URL:-https://gitlab.com/api/graphql}"
project_gid="gid://gitlab/Project/${project_id}"

gql() { # query variables_json
  curl --silent --show-error --fail-with-body \
    --header "Authorization: Bearer ${GITLAB_TOKEN}" --header "Content-Type: application/json" \
    --data "$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')" "$graphql"
}

check() { # response mutation_name
  errs=$(printf '%s' "$1" | jq -c "[.errors[]?.message] + (.data.$2.errors // [])")
  if [ "$errs" != "[]" ]; then echo "$2 failed: $errs" >&2; exit 1; fi
}

# Is the flow already enabled in the project (configured items include our own flows)?
configured=$(gql 'query($p: ProjectID!) { aiCatalogConfiguredItems(projectId: $p) { nodes { id item { id name } } } }' \
  "$(jq -n --arg p "$project_gid" '{p: $p}')")
item_id=$(printf '%s' "$configured" | jq -r --arg n "$name" '.data.aiCatalogConfiguredItems.nodes[] | select(.item.name == $n) | .item.id' | head -1)
definition=$(cat "$file")

if [ -n "$item_id" ]; then
  # A released version is immutable, so only publish when the definition actually changed.
  current=$(gql 'query($id: AiCatalogItemID!) { aiCatalogItem(id: $id) { latestVersion { ... on AiCatalogFlowVersion { definition } } } }' \
    "$(jq -n --arg id "$item_id" '{id: $id}')" | jq -r '.data.aiCatalogItem.latestVersion.definition // ""')
  if [ "$current" = "$definition" ]; then
    echo "Flow ${name} (${item_id}) is already up to date."
    exit 0
  fi
  res=$(gql 'mutation($id: AiCatalogItemID!, $def: String!, $desc: String!) {
      aiCatalogFlowUpdate(input: { id: $id, definition: $def, description: $desc, release: true, versionBump: PATCH }) {
        errors item { id latestVersion { versionName } } } }' \
    "$(jq -n --arg id "$item_id" --arg def "$definition" --arg desc "$description" '{id: $id, def: $def, desc: $desc}')")
  check "$res" aiCatalogFlowUpdate
  echo "Updated flow ${name} (${item_id}) to version $(printf '%s' "$res" | jq -r '.data.aiCatalogFlowUpdate.item.latestVersion.versionName // "?"')"
else
  res=$(gql 'mutation($p: ProjectID!, $name: String!, $def: String!, $desc: String!) {
      aiCatalogFlowCreate(input: { projectId: $p, name: $name, description: $desc, definition: $def, release: true, visibility: PRIVATE }) {
        errors item { id } } }' \
    "$(jq -n --arg p "$project_gid" --arg name "$name" --arg def "$definition" --arg desc "$description" '{p: $p, name: $name, def: $def, desc: $desc}')")
  check "$res" aiCatalogFlowCreate
  item_id=$(printf '%s' "$res" | jq -r .data.aiCatalogFlowCreate.item.id)
  echo "Created flow ${name} (${item_id})"

  res=$(gql 'mutation($item: AiCatalogItemID!, $p: ProjectID!) {
      aiCatalogItemConsumerCreate(input: { itemId: $item, target: { projectId: $p }, triggerTypes: ["mention"] }) {
        errors itemConsumer { id } } }' \
    "$(jq -n --arg item "$item_id" --arg p "$project_gid" '{item: $item, p: $p}')")
  check "$res" aiCatalogItemConsumerCreate
  echo "Enabled in project ${project_id}: consumer $(printf '%s' "$res" | jq -r .data.aiCatalogItemConsumerCreate.itemConsumer.id)"
fi
