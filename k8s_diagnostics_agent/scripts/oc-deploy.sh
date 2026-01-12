#!/usr/bin/env bash
set -euo pipefail

# Deploy the K8s Diagnostics Agent (MCP + RAG) using OpenShift ImageStream + BuildConfig (binary Docker build).
# Reads configuration from .env at the repo root (NAMESPACE, LLAMA_BASE_URL, VECTOR_STORE_IDS, VECTOR_DB_ID,
# MCP_SERVER_URL, MCP_SERVER_LABEL).
#
# Usage:
#   ./k8s_diagnostics_agent/scripts/oc-deploy.sh
#
# Assumptions:
# - You are logged in to the OpenShift cluster (oc login)
# - The target project exists or you have permission to create it

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE="$ROOT/k8s_diagnostics_agent/template.yaml"
BUILDS="$ROOT/k8s_diagnostics_agent/openshift/10-builds-imagestreams.yaml"

# Load .env if present (exports variables)
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ROOT/.env"
  set +a
fi

NAMESPACE="${NAMESPACE:-llama-stack-demo}"
LLAMA_BASE_URL="${LLAMA_BASE_URL:-http://lsd-llama-milvus-inline-service.default.svc.cluster.local:8321}"
VECTOR_STORE_IDS="${VECTOR_STORE_IDS:-}"
VECTOR_DB_ID="${VECTOR_DB_ID:-}"
MCP_SERVER_URL="${MCP_SERVER_URL:-http://kubernetes-mcp-server.llama-stack-demo.svc.cluster.local:8080/sse}"
MCP_SERVER_LABEL="${MCP_SERVER_LABEL:-kubernetes-mcp}"
ROUTE_TIMEOUT="${ROUTE_TIMEOUT:-5m}"

echo "Deploying K8s Diagnostics Agent to namespace: $NAMESPACE"
echo

# Ensure project exists
if ! oc get project "$NAMESPACE" >/dev/null 2>&1; then
  echo "Creating project $NAMESPACE (if permitted)..."
  oc new-project "$NAMESPACE" || true
fi

echo "Applying ImageStream and BuildConfig..."
oc apply -n "$NAMESPACE" -f "$BUILDS"

echo "Starting binary Docker build from k8s_diagnostics_agent/ ..."
oc start-build -n "$NAMESPACE" k8-diagnostics-agent --from-dir="$ROOT/k8s_diagnostics_agent" --wait --follow

APP_BUILD_STAMP="$(date +%s)"

echo "Processing template and applying Deployment/Service/Route..."
oc process -f "$TEMPLATE" \
  -p NAMESPACE="$NAMESPACE" \
  -p LLAMA_BASE_URL="$LLAMA_BASE_URL" \
  -p VECTOR_STORE_IDS="$VECTOR_STORE_IDS" \
  -p VECTOR_DB_ID="$VECTOR_DB_ID" \
  -p MCP_SERVER_URL="$MCP_SERVER_URL" \
  -p MCP_SERVER_LABEL="$MCP_SERVER_LABEL" \
  -p APP_BUILD_STAMP="$APP_BUILD_STAMP" \
  | oc apply -f -

# Ensure router timeout is long enough for diagnostics (defaults to 5m; override via ROUTE_TIMEOUT)
echo "Annotating route timeout to ${ROUTE_TIMEOUT}..."
oc -n "$NAMESPACE" annotate route k8-diagnostics-agent \
  "haproxy.router.openshift.io/timeout=${ROUTE_TIMEOUT}" --overwrite || true

# Cleanup: remove stray numbered ConfigMaps from previous runs to keep the demo tidy
echo "Pruning stray k8-diagnostics-agent-[0-9]* ConfigMaps (ca/global-ca/sys-config)..."
oc get cm -n "$NAMESPACE" -o name \
  | grep -E '^configmap/k8-diagnostics-agent-[0-9]+-(ca|global-ca|sys-config)$' \
  | xargs -r oc delete -n "$NAMESPACE" || true

echo "Forcing rollout restart to pick up the latest image..."
oc rollout restart -n "$NAMESPACE" deploy/k8-diagnostics-agent || true

echo "Waiting for rollout..."
oc rollout status -n "$NAMESPACE" deploy/k8-diagnostics-agent

echo
ROUTE_HOST="$(oc get route -n "$NAMESPACE" k8-diagnostics-agent -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "$ROUTE_HOST" ]]; then
  echo "Route host: $ROUTE_HOST"
  echo
  echo "Example call:"
  echo "  curl -s -X POST https://$ROUTE_HOST/diagnose -H 'Content-Type: application/json' -d '{\"result\":{\"short_description\":\"Payment failed: HTTP 502\",\"u_namespace\":\"special-payment-project\"}}' | jq ."
else
  echo "Route not found yet. Check the namespace for the route and try again:"
  echo "  oc get route -n $NAMESPACE"
fi


