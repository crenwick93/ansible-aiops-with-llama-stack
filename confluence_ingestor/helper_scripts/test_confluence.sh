#!/usr/bin/env bash
set -euo pipefail

# Confluence access check & page listing using curl + jq.
# Loads repo-level .env if present; env vars override .env.
# Requires: curl, jq.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo root is two levels up from helper_scripts (confluence_ingestor/..)
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
  set +a
fi

: "${CONF_USER:?Set CONF_USER}"
: "${CONF_API_TOKEN:?Set CONF_API_TOKEN}"
: "${CONF_CLOUD_ID:?Set CONF_CLOUD_ID}"
: "${SPACE_NAME:?Set SPACE_NAME}"
TEST_LIMIT="${TEST_LIMIT:-10}"

API_BASE="https://api.atlassian.com/ex/confluence/${CONF_CLOUD_ID}/wiki/rest/api"

resolve_space_key() {
  local start=0
  local page_size=50
  while true; do
    local resp
    resp=$(
      curl -fsS -u "$CONF_USER:$CONF_API_TOKEN" "$API_BASE/space" \
        --get \
        --data-urlencode "start=${start}" \
        --data-urlencode "limit=${page_size}"
    )
    local key
    key=$(jq -r --arg NAME "$SPACE_NAME" '.results[] | select(.name|ascii_downcase == ($NAME|ascii_downcase)) | .key' <<<"$resp" | head -n1)
    if [[ -n "${key}" ]]; then
      printf '%s\n' "$key"
      return 0
    fi
    local count
    count=$(jq '.results | length' <<<"$resp")
    if (( count < page_size )); then
      break
    fi
    start=$(( start + count ))
  done
  return 1
}

list_pages() {
  local space_key="$1"
  local fetched=0
  local start=0
  while (( fetched < TEST_LIMIT )); do
    local page_limit=$(( TEST_LIMIT - fetched ))
    if (( page_limit > 50 )); then
      page_limit=50
    fi
    local resp
    resp=$(
      curl -fsS -u "$CONF_USER:$CONF_API_TOKEN" "$API_BASE/content/search" \
        --get \
        --data-urlencode "cql=type=page and space=\"${space_key}\"" \
        --data-urlencode "limit=${page_limit}" \
        --data-urlencode "start=${start}" \
        --data-urlencode "expand=history.lastUpdated"
    )
    jq -r '.results[] | "- \(.id): \(.title) (\(.history.lastUpdated.when // ""))"' <<<"$resp"
    local count
    count=$(jq '.results | length' <<<"$resp")
    fetched=$(( fetched + count ))
    if (( count < page_limit )); then
      break
    fi
    start=$(( start + count ))
  done
}

echo "Checking Confluence access for space '${SPACE_NAME}' (limit=${TEST_LIMIT}) …"
SPACE_KEY="$(resolve_space_key)" || {
  echo "Space '${SPACE_NAME}' not found or no access." >&2
  exit 3
}
echo "SPACE_KEY: ${SPACE_KEY}"
echo "Listing pages:"
list_pages "${SPACE_KEY}"

