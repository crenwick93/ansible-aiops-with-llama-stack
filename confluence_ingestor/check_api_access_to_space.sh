#!/usr/bin/env bash
set -euo pipefail

# Minimal Confluence credential + space access check.
# Loads top-level .env (repo root) if present so you can run from repo root.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
  set +a
fi

: "${CONF_USER:?Set CONF_USER}"
: "${CONF_API_TOKEN:?Set CONF_API_TOKEN}"
: "${CONF_CLOUD_ID:?Set CONF_CLOUD_ID}"

API_BASE="https://api.atlassian.com/ex/confluence/$CONF_CLOUD_ID/wiki/rest/api"
URL="$API_BASE/user/current"
SPACE_NAME="${SPACE_NAME:-Known Issues}"

if ! curl -fsS -u "$CONF_USER:$CONF_API_TOKEN" "$URL" >/dev/null; then
  echo "FAIL" >&2
  exit 1
fi

# Verify the credentials can see the target space by name
SPACE_KEY=$(curl -fsS -u "$CONF_USER:$CONF_API_TOKEN" "$API_BASE/space?limit=250" \
  | jq -r --arg NAME "$SPACE_NAME" '.results[] | select(.name==$NAME) | .key' | head -n1)

if [ -z "$SPACE_KEY" ]; then
  echo "FAIL: cannot access space named '$SPACE_NAME' (not found or no permission)" >&2
  exit 1
fi

echo "OK: space '$SPACE_NAME' accessible (key=$SPACE_KEY)"