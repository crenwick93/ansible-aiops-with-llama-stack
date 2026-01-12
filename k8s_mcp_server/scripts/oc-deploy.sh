#!/usr/bin/env bash
set -euo pipefail

# Deploy the Kubernetes MCP Server into an OpenShift cluster using the repo template.
# Usage examples:
#   ./k8s_mcp_server/scripts/oc-deploy.sh
#   ./k8s_mcp_server/scripts/oc-deploy.sh --deploy-namespace llama-stack-demo --target-namespace special-payment-project
#   ./k8s_mcp_server/scripts/oc-deploy.sh --app-name kubernetes-mcp-server --log-level 3 --read-only true
#
# Supports a .env at the repository root with any of these vars:
#   DEPLOY_NAMESPACE, TARGET_NAMESPACE, APP_NAME, IMAGE, IMAGE_TAG,
#   LOG_LEVEL, READ_ONLY, CPU_REQUEST, MEMORY_REQUEST, CPU_LIMIT, MEMORY_LIMIT
#
# The service will be reachable at:
#   http://$APP_NAME.$DEPLOY_NAMESPACE.svc.cluster.local:8080/sse

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${THIS_DIR}/../.." && pwd)"
TEMPLATE="${REPO_ROOT}/k8s_mcp_server/template.yaml"  # OpenShift template for MCP server

# Defaults (overridable via flags or .env)
DEPLOY_NAMESPACE="${DEPLOY_NAMESPACE:-llama-stack-demo}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-special-payment-project}"
APP_NAME="${K8S_APP_NAME:-${APP_NAME:-kubernetes-mcp-server}}"
IMAGE="${IMAGE:-quay.io/manusa/kubernetes_mcp_server}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
LOG_LEVEL="${LOG_LEVEL:-2}"
READ_ONLY="${READ_ONLY:-true}"
CPU_REQUEST="${CPU_REQUEST:-50m}"
MEMORY_REQUEST="${MEMORY_REQUEST:-64Mi}"
CPU_LIMIT="${CPU_LIMIT:-200m}"
MEMORY_LIMIT="${MEMORY_LIMIT:-256Mi}"

# Load .env from repo root to allow quick overrides without flags
if [[ -f "${REPO_ROOT}/.env" ]]; then
  echo "Loading environment from ${REPO_ROOT}/.env"
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${REPO_ROOT}/.env" | xargs -I{} echo {})
  # Re-apply defaults if not overridden by .env
  DEPLOY_NAMESPACE="${DEPLOY_NAMESPACE:-llama-stack-demo}"
  TARGET_NAMESPACE="${TARGET_NAMESPACE:-special-payment-project}"
  APP_NAME="${K8S_APP_NAME:-${APP_NAME:-kubernetes-mcp-server}}"
  IMAGE="${IMAGE:-quay.io/manusa/kubernetes_mcp_server}"
  IMAGE_TAG="${IMAGE_TAG:-latest}"
  LOG_LEVEL="${LOG_LEVEL:-2}"
  READ_ONLY="${READ_ONLY:-true}"
  CPU_REQUEST="${CPU_REQUEST:-50m}"
  MEMORY_REQUEST="${MEMORY_REQUEST:-64Mi}"
  CPU_LIMIT="${CPU_LIMIT:-200m}"
  MEMORY_LIMIT="${MEMORY_LIMIT:-256Mi}"
fi

print_usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --deploy-namespace NAME   Namespace to deploy MCP server (default: ${DEPLOY_NAMESPACE})
  --target-namespace NAME   Namespace MCP is allowed to view (default: ${TARGET_NAMESPACE})
  --app-name NAME           Application name (default: ${APP_NAME})
  --image IMAGE             Container image (default: ${IMAGE})
  --image-tag TAG           Image tag (default: ${IMAGE_TAG})
  --log-level N             Logging verbosity 0-9 (default: ${LOG_LEVEL})
  --read-only true|false    Run server read-only (default: ${READ_ONLY})
  --cpu-request VAL         CPU request (default: ${CPU_REQUEST})
  --memory-request VAL      Memory request (default: ${MEMORY_REQUEST})
  --cpu-limit VAL           CPU limit (default: ${CPU_LIMIT})
  --memory-limit VAL        Memory limit (default: ${MEMORY_LIMIT})
  -h, --help                Show this help
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy-namespace) DEPLOY_NAMESPACE="$2"; shift 2;;
    --target-namespace) TARGET_NAMESPACE="$2"; shift 2;;
    --app-name) APP_NAME="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --image-tag) IMAGE_TAG="$2"; shift 2;;
    --log-level) LOG_LEVEL="$2"; shift 2;;
    --read-only) READ_ONLY="$2"; shift 2;;
    --cpu-request) CPU_REQUEST="$2"; shift 2;;
    --memory-request) MEMORY_REQUEST="$2"; shift 2;;
    --cpu-limit) CPU_LIMIT="$2"; shift 2;;
    --memory-limit) MEMORY_LIMIT="$2"; shift 2;;
    -h|--help) print_usage; exit 0;;
    *) echo "Unknown option: $1"; print_usage; exit 1;;
  esac
done

# Ensure dependencies are present
if ! command -v oc >/dev/null 2>&1; then
  echo "Error: 'oc' CLI not found. Install and login first."
  exit 1
fi

echo "Ensuring deploy namespace '${DEPLOY_NAMESPACE}' exists..."  # Creates if missing
if ! oc get namespace "${DEPLOY_NAMESPACE}" >/dev/null 2>&1; then
  oc new-project "${DEPLOY_NAMESPACE}" || true
fi

echo "Checking target namespace '${TARGET_NAMESPACE}'..."
if ! oc get namespace "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
  echo "Error: Target namespace '${TARGET_NAMESPACE}' does not exist."
  echo "Please create it before deploying, e.g.: oc new-project \"${TARGET_NAMESPACE}\""
  exit 1
fi

echo "Deploying MCP Server '${APP_NAME}' to '${DEPLOY_NAMESPACE}' (view access to '${TARGET_NAMESPACE}')..."
# Render and apply the OpenShift template with current parameters
oc process -f "${TEMPLATE}" \
  -p DEPLOY_NAMESPACE="${DEPLOY_NAMESPACE}" \
  -p TARGET_NAMESPACE="${TARGET_NAMESPACE}" \
  -p APP_NAME="${APP_NAME}" \
  -p IMAGE="${IMAGE}" \
  -p IMAGE_TAG="${IMAGE_TAG}" \
  -p LOG_LEVEL="${LOG_LEVEL}" \
  -p READ_ONLY="${READ_ONLY}" \
  -p CPU_REQUEST="${CPU_REQUEST}" \
  -p MEMORY_REQUEST="${MEMORY_REQUEST}" \
  -p CPU_LIMIT="${CPU_LIMIT}" \
  -p MEMORY_LIMIT="${MEMORY_LIMIT}" \
| oc apply -f -

echo "Waiting for rollout..."
oc -n "${DEPLOY_NAMESPACE}" rollout status deploy/"${APP_NAME}" --timeout=180s || true

echo
echo "MCP Server deployed."
echo "Service:"
echo "  kubernetes-mcp-server URL (ClusterIP): http://${APP_NAME}.${DEPLOY_NAMESPACE}.svc.cluster.local:8080"
echo "MCP endpoint (SSE):"
echo "  http://${APP_NAME}.${DEPLOY_NAMESPACE}.svc.cluster.local:8080/sse"
echo
echo "Done."


