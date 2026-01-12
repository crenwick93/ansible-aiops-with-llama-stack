#!/usr/bin/env bash
set -euo pipefail

# Remove Llama Stack resources from OpenShift (no flags, no namespace deletion).
# Deletes the LlamaStackDistribution CR, its ConfigMap (lsd-run), and Secret
# (llama-stack-inference-model-secret).

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${THIS_DIR}/../../.." && pwd)"

# Load .env if present at repo root
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${REPO_ROOT}/.env" | xargs -I{} echo {})
fi

NAMESPACE="${NAMESPACE:-llama-stack-demo}"
LSD_NAME="${LSD_NAME:-lsd-llama-milvus-inline}"

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: 'oc' CLI not found. Install and login first."
  exit 1
fi

echo "Removing Llama Stack resources from '${NAMESPACE}'..."

# Delete the CR first (ownerReferences should clean most children)
oc -n "${NAMESPACE}" delete llamastackdistribution "${LSD_NAME}" --ignore-not-found=true || true

# Delete supporting resources created by template
oc -n "${NAMESPACE}" delete configmap lsd-run --ignore-not-found=true || true
oc -n "${NAMESPACE}" delete secret llama-stack-inference-model-secret --ignore-not-found=true || true

echo "Waiting for Llama Stack resources to terminate (best-effort)..."
oc -n "${NAMESPACE}" wait --for=delete llamastackdistribution/"${LSD_NAME}" --timeout=120s >/dev/null 2>&1 || true

echo
echo "Done. Namespace was NOT deleted: ${NAMESPACE}"
echo


