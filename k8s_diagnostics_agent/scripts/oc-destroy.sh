#!/usr/bin/env bash
set -euo pipefail

# Remove the K8s Diagnostics Agent resources (Deployment, Service, Route, BuildConfig, ImageStream)
# from an OpenShift cluster without deleting the namespace.
#
# Usage:
#   ./k8s_diagnostics_agent/scripts/oc-destroy.sh
#
# Reads NAMESPACE from $REPO_ROOT/.env if present; defaults to llama-stack-demo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load .env if present
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ROOT/.env"
  set +a
fi

NAMESPACE="${NAMESPACE:-llama-stack-demo}"
APP_NAME="k8-diagnostics-agent"

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: 'oc' CLI not found. Install and login first."
  exit 1
fi

echo "Removing K8s Diagnostics Agent resources from namespace: ${NAMESPACE}"

# Workload first
oc -n "${NAMESPACE}" delete deployment "${APP_NAME}" --ignore-not-found=true || true
oc -n "${NAMESPACE}" delete rs -l "app=${APP_NAME}" --ignore-not-found=true || true
oc -n "${NAMESPACE}" delete pod -l "app=${APP_NAME}" --ignore-not-found=true || true

# Service and Route
oc -n "${NAMESPACE}" delete service "${APP_NAME}" --ignore-not-found=true || true
oc -n "${NAMESPACE}" delete route "${APP_NAME}" --ignore-not-found=true || true

# Build pipeline artifacts
oc -n "${NAMESPACE}" delete buildconfig "${APP_NAME}" --ignore-not-found=true || true
oc -n "${NAMESPACE}" delete imagestream "${APP_NAME}" --ignore-not-found=true || true

echo "Waiting for resources to terminate (best-effort)..."
oc -n "${NAMESPACE}" wait --for=delete deployment/"${APP_NAME}" --timeout=90s >/dev/null 2>&1 || true
oc -n "${NAMESPACE}" wait --for=delete pod -l "app=${APP_NAME}" --timeout=90s >/dev/null 2>&1 || true

echo
echo "Done. Namespace was NOT deleted: ${NAMESPACE}"
echo


