#!/usr/bin/env bash
set -euo pipefail

# Remove the Kubernetes MCP Server resources from an OpenShift cluster, without deleting namespaces.
# Usage examples:
#   ./k8s_mcp_server/oc-destroy.sh
#   ./k8s_mcp_server/oc-destroy.sh --deploy-namespace llama-stack-demo --target-namespace special-payment-project
#   ./k8s_mcp_server/oc-destroy.sh --app-name kubernetes-mcp-server
#
# Supports a .env at the repository root with any of these vars:
#   DEPLOY_NAMESPACE, TARGET_NAMESPACE, APP_NAME
#
# This script deletes:
# - RoleBinding (${APP_NAME}-view) in TARGET_NAMESPACE
# - Deployment, Service, NetworkPolicy, ConfigMap, ServiceAccount in DEPLOY_NAMESPACE
# It does NOT delete namespaces.

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${THIS_DIR}/.." && pwd)"

# Defaults (overridable via flags or .env)
DEPLOY_NAMESPACE="${DEPLOY_NAMESPACE:-llama-stack-demo}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-special-payment-project}"
APP_NAME="${K8S_APP_NAME:-${APP_NAME:-kubernetes-mcp-server}}"

# Load .env from repo root to match deploy script defaults
if [[ -f "${REPO_ROOT}/.env" ]]; then
  echo "Loading environment from ${REPO_ROOT}/.env"
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${REPO_ROOT}/.env" | xargs -I{} echo {})
  # Re-apply defaults if not overridden by .env
  DEPLOY_NAMESPACE="${DEPLOY_NAMESPACE:-llama-stack-demo}"
  TARGET_NAMESPACE="${TARGET_NAMESPACE:-special-payment-project}"
  APP_NAME="${K8S_APP_NAME:-${APP_NAME:-kubernetes-mcp-server}}"
fi

print_usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --deploy-namespace NAME   Namespace where MCP server was deployed (default: ${DEPLOY_NAMESPACE})
  --target-namespace NAME   Namespace MCP was granted view access (default: ${TARGET_NAMESPACE})
  --app-name NAME           Application name (default: ${APP_NAME})
  -h, --help                Show this help
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy-namespace) DEPLOY_NAMESPACE="$2"; shift 2;;
    --target-namespace) TARGET_NAMESPACE="$2"; shift 2;;
    --app-name) APP_NAME="$2"; shift 2;;
    -h|--help) print_usage; exit 0;;
    *) echo "Unknown option: $1"; print_usage; exit 1;;
  esac
done

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: 'oc' CLI not found. Install and login first."
  exit 1
fi

echo "Removing MCP Server '${APP_NAME}' resources..."
echo "  Deploy namespace : ${DEPLOY_NAMESPACE}"
echo "  Target namespace : ${TARGET_NAMESPACE}"
echo

# Delete workload first to stop pods
oc -n "${DEPLOY_NAMESPACE}" delete deployment "${APP_NAME}" --ignore-not-found=true || true

# Clean up dependent controllers (if any remain via labels)
oc -n "${DEPLOY_NAMESPACE}" delete rs -l "app.kubernetes.io/name=${APP_NAME}" --ignore-not-found=true || true
oc -n "${DEPLOY_NAMESPACE}" delete pod -l "app.kubernetes.io/name=${APP_NAME}" --ignore-not-found=true || true

# Delete service and other namespaced resources
oc -n "${DEPLOY_NAMESPACE}" delete service "${APP_NAME}" --ignore-not-found=true || true
oc -n "${DEPLOY_NAMESPACE}" delete networkpolicy "${APP_NAME}-ingress" --ignore-not-found=true || true
oc -n "${DEPLOY_NAMESPACE}" delete configmap "${APP_NAME}-config" --ignore-not-found=true || true

# Delete ServiceAccount last in deploy namespace
oc -n "${DEPLOY_NAMESPACE}" delete serviceaccount "${APP_NAME}" --ignore-not-found=true || true

# Delete RoleBinding in target namespace
oc -n "${TARGET_NAMESPACE}" delete rolebinding "${APP_NAME}-view" --ignore-not-found=true || true

echo
echo "Waiting for resources to terminate (best-effort)..."
oc -n "${DEPLOY_NAMESPACE}" wait --for=delete deployment/"${APP_NAME}" --timeout=60s >/dev/null 2>&1 || true
oc -n "${DEPLOY_NAMESPACE}" wait --for=delete pod -l "app.kubernetes.io/name=${APP_NAME}" --timeout=60s >/dev/null 2>&1 || true

echo
echo "Done. Namespaces were NOT deleted:"
echo "  - ${DEPLOY_NAMESPACE}"
echo "  - ${TARGET_NAMESPACE}"
echo


