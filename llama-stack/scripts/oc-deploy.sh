#!/usr/bin/env bash
set -euo pipefail

# Deploy Llama Stack Distribution on OpenShift using the included templates.
# Usage: populate $REPO_ROOT/.env and run ./llama-stack/scripts/oc-deploy.sh
# Optional flags: --reset-vector-db (force new DB), --llama-local-port <PORT>

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${THIS_DIR}/../.." && pwd)"

# Defaults (can be overridden by flags or .env)
NAMESPACE="${NAMESPACE:-llama-stack-demo}"
LSD_NAME="${LSD_NAME:-lsd-llama-milvus-inline}"
INFERENCE_MODEL="${INFERENCE_MODEL:-mistral-small-24b-w8a8}"
VLLM_URL="${VLLM_URL:-}"
VLLM_API_TOKEN="${VLLM_API_TOKEN:-}"
VLLM_TLS_VERIFY="${VLLM_TLS_VERIFY:-true}"
LLAMA_LOCAL_PORT="${LLAMA_LOCAL_PORT:-8321}"
RESET_VECTOR_DB="false"
VECTOR_DB_ID="${VECTOR_DB_ID:-}"
API_BASE_URL=""  # Localhost URL used for port-forwarded access

TEMPLATE_LSD="${REPO_ROOT}/llama-stack/template.yaml"

# Load .env at repo root so users only set values in one place
if [[ -f "${REPO_ROOT}/.env" ]]; then
  echo "Loading environment from ${REPO_ROOT}/.env"
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${REPO_ROOT}/.env" | xargs -I{} echo {})
  # Re-evaluate defaults if .env provided values
  NAMESPACE="${NAMESPACE:-llama-stack-demo}"
  LSD_NAME="${LSD_NAME:-lsd-llama-milvus-inline}"
  INFERENCE_MODEL="${INFERENCE_MODEL:-mistral-small-24b-w8a8}"
  VLLM_URL="${VLLM_URL:-}"
  VLLM_API_TOKEN="${VLLM_API_TOKEN:-}"
  VLLM_TLS_VERIFY="${VLLM_TLS_VERIFY:-true}"
  LLAMA_LOCAL_PORT="${LLAMA_LOCAL_PORT:-8321}"
  VECTOR_DB_ID="${VECTOR_DB_ID:-}"
fi

# Minimal flag handling (optional overrides)
print_usage() {
  cat <<EOF
Usage: $0 [--reset-vector-db] [--llama-local-port PORT]
Defaults come from \$REPO_ROOT/.env; flags override.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-vector-db) RESET_VECTOR_DB="true"; shift 1;;
    --llama-local-port) LLAMA_LOCAL_PORT="$2"; shift 2;;
    -h|--help) print_usage; exit 0;;
    *) echo "Unknown option: $1"; print_usage; exit 1;;
  esac
done

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: 'oc' CLI not found. Install and login first."
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "Error: 'curl' not found. Please install curl."
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' not found. Please install jq."
  exit 1
fi

update_env_var() {
  # Arguments: VAR_NAME VAR_VALUE
  # Upserts VAR_NAME=VAR_VALUE into ${REPO_ROOT}/.env
  local var_name="$1"
  local var_value="$2"
  local env_file="${REPO_ROOT}/.env"
  touch "${env_file}"
  if grep -qE "^${var_name}=" "${env_file}"; then
    # Replace existing line
    tmp_file="$(mktemp)"
    sed -E "s|^(${var_name}=).*|\1${var_value}|g" "${env_file}" > "${tmp_file}"
    mv "${tmp_file}" "${env_file}"
  else
    echo "${var_name}=${var_value}" >> "${env_file}"
  fi
}

get_llama_pod_name() {
  # Find a Running pod that contains container named "llama-stack"
  oc get pods -n "${NAMESPACE}" -o json | jq -r '
    .items[]
    | select(.status.phase=="Running")
    | select(any(.status.containerStatuses[]?; .ready == true))
    | select(any(.spec.containers[]?; .name=="llama-stack"))
    | .metadata.name
  ' | head -n 1
}

wait_for_llama_ready_and_port_forward() {
  local timeout_seconds=600
  local interval_seconds=5
  local waited=0
  local pod_name=""

  echo "Waiting for Llama Stack pod to be Running and Ready (timeout ${timeout_seconds}s)..." >&2
  while [[ "${waited}" -lt "${timeout_seconds}" ]]; do
    pod_name="$(get_llama_pod_name || true)"
    if [[ -n "${pod_name}" ]]; then
      # Double check Ready condition
      if oc get pod "${pod_name}" -n "${NAMESPACE}" -o json | jq -e '.status.conditions[] | select(.type=="Ready" and .status=="True")' >/dev/null; then
        echo "Found Ready pod: ${pod_name}" >&2
        break
      fi
    fi
    sleep "${interval_seconds}"
    waited=$(( waited + interval_seconds ))
  done

  if [[ -z "${pod_name}" ]]; then
    echo "Error: Timed out waiting for Llama Stack pod to be ready." >&2
    oc get pods -n "${NAMESPACE}" >&2
    exit 1
  fi

  echo "Starting temporary port-forward from localhost:${LLAMA_LOCAL_PORT} -> pod/${pod_name}:8321 ..." >&2
  oc -n "${NAMESPACE}" port-forward "pod/${pod_name}" "${LLAMA_LOCAL_PORT}:8321" >/dev/null 2>&1 &
  local pf_pid=$!

  # Brief warm-up to allow port-forward to start listening
  sleep 1

  # Always use localhost when port-forward is active
  API_BASE_URL="http://127.0.0.1:${LLAMA_LOCAL_PORT}"
  echo "Waiting for API on ${API_BASE_URL} to respond..." >&2
  local api_waited=0
  local api_timeout=120
  while [[ "${api_waited}" -lt "${api_timeout}" ]]; do
    if curl -s -o /dev/null "${API_BASE_URL}/v1/vector_stores" 2>/dev/null; then
      echo "API responded on ${API_BASE_URL}" >&2
      echo "${pf_pid}"
      return 0
    fi
    sleep 2
    api_waited=$(( api_waited + 2 ))
  done

  echo "Error: API did not become reachable at ${API_BASE_URL} within ${api_timeout}s." >&2
  kill "${pf_pid}" >/dev/null 2>&1 || true
  exit 1
}

echo "Ensuring namespace '${NAMESPACE}' exists..."
if ! oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  oc new-project "${NAMESPACE}" || true
fi

echo "Deploying Llama Stack Distribution '${LSD_NAME}' into '${NAMESPACE}'..."
oc process -f "${TEMPLATE_LSD}" \
  -p NAMESPACE="${NAMESPACE}" \
  -p LSD_NAME="${LSD_NAME}" \
  -p INFERENCE_MODEL="${INFERENCE_MODEL}" \
  -p VLLM_URL="${VLLM_URL}" \
  -p VLLM_API_TOKEN="${VLLM_API_TOKEN}" \
  -p VLLM_TLS_VERIFY="${VLLM_TLS_VERIFY}" \
| oc apply -f -

echo "Applied resources. Waiting briefly for pods to appear..."
sleep 3

echo "Current status:"
oc get llamastackdistributions.llamastack.io -n "${NAMESPACE}" || true
oc get pods -n "${NAMESPACE}"

echo
echo "Waiting for Llama Stack to be ready and accept requests..."
PF_PID="$(wait_for_llama_ready_and_port_forward)"
# Ensure API_BASE_URL is set in parent scope for subsequent curl calls
API_BASE_URL="http://127.0.0.1:${LLAMA_LOCAL_PORT}"
# Ensure cleanup of the port-forward when the script exits
trap "kill ${PF_PID} >/dev/null 2>&1 || true" EXIT

echo
echo "Managing Vector DB..."
if [[ "${RESET_VECTOR_DB}" == "true" ]]; then
  if [[ -n "${VECTOR_DB_ID}" ]]; then
    echo "Reset requested: deleting existing Vector DB '${VECTOR_DB_ID}'..."
    # Attempt delete; ignore failures
    curl -s -X DELETE "${API_BASE_URL}/v1/vector_stores/${VECTOR_DB_ID}" -H 'content-type: application/json' -o /dev/null || true
  else
    echo "Reset requested, but no existing VECTOR_DB_ID found. Proceeding to create a new one."
  fi
  VECTOR_DB_ID=""
fi

if [[ -z "${VECTOR_DB_ID}" ]]; then
  echo "Creating new Vector DB..."
  resp_file="$(mktemp)"
  http_code="$(curl -sS -o "${resp_file}" -w '%{http_code}' -X POST "${API_BASE_URL}/v1/vector_stores" -H 'content-type: application/json' -d '{}')"
  if [[ "${http_code}" != "200" && "${http_code}" != "201" ]]; then
    echo "Error: Vector DB create failed (HTTP ${http_code}). Response body:" >&2
    cat "${resp_file}" >&2 || true
    rm -f "${resp_file}" || true
    exit 1
  fi
  VECTOR_DB_ID="$(jq -r '.id // empty' "${resp_file}" 2>/dev/null || true)"
  rm -f "${resp_file}" || true
  if [[ -z "${VECTOR_DB_ID}" || "${VECTOR_DB_ID}" == "null" ]]; then
    echo "Error: Failed to create vector DB (no id returned)." >&2
    exit 1
  fi
  update_env_var "VECTOR_DB_ID" "${VECTOR_DB_ID}"
  echo "VECTOR_DB_ID created: ${VECTOR_DB_ID}"
else
  echo "Existing VECTOR_DB_ID detected: ${VECTOR_DB_ID}"
  # Validate that the stored VECTOR_DB_ID actually exists on the server
  validate_code="$(curl -sS -o /dev/null -w '%{http_code}' "${API_BASE_URL}/v1/vector_stores/${VECTOR_DB_ID}" || true)"
  if [[ "${validate_code}" != "200" ]]; then
    echo "Stored VECTOR_DB_ID not found (HTTP ${validate_code}). Creating a new Vector DB..."
    resp_file="$(mktemp)"
    http_code="$(curl -sS -o "${resp_file}" -w '%{http_code}' -X POST "${API_BASE_URL}/v1/vector_stores" -H 'content-type: application/json' -d '{}')"
    if [[ "${http_code}" != "200" && "${http_code}" != "201" ]]; then
      echo "Error: Vector DB create failed (HTTP ${http_code}). Response body:" >&2
      cat "${resp_file}" >&2 || true
      rm -f "${resp_file}" || true
      exit 1
    fi
    VECTOR_DB_ID="$(jq -r '.id // empty' "${resp_file}" 2>/dev/null || true)"
    rm -f "${resp_file}" || true
    if [[ -z "${VECTOR_DB_ID}" || "${VECTOR_DB_ID}" == "null" ]]; then
      echo "Error: Failed to create vector DB (no id returned)." >&2
      exit 1
    fi
    update_env_var "VECTOR_DB_ID" "${VECTOR_DB_ID}"
    echo "New VECTOR_DB_ID created: ${VECTOR_DB_ID}"
  fi
fi

echo
echo "You can use VECTOR_DB_ID=${VECTOR_DB_ID}"
echo "API_BASE_URL=${API_BASE_URL}"
echo "Done."


