#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/oc-deploy.sh <APPS_DOMAIN>
# Example: ./scripts/oc-deploy.sh apps.cluster-xxxx.example.com

APPS_DOMAIN="${1:-}"
if [[ -z "$APPS_DOMAIN" ]]; then
  echo "Provide your OpenShift apps domain. Example:"
  echo "  ./scripts/oc-deploy.sh apps.cluster-xxxx.example.com"
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${ROOT}/.." && pwd)"

# Load top-level .env if present (for ServiceNow settings, etc.)
if [[ -f "$REPO_ROOT/.env" ]]; then
  echo "Loading environment from $REPO_ROOT/.env"
  # shellcheck disable=SC2046
  export $(grep -v '^#' "$REPO_ROOT/.env" | xargs -I{} echo {})
fi

# Login assumed; project create/apply
oc apply -f "$ROOT/openshift/00-namespace.yaml"
oc label namespace special-payment-project openshift.io/user-monitoring=true --overwrite || true

# BuildConfigs + ImageStreams
oc apply -f "$ROOT/openshift/10-builds-imagestreams.yaml"

# Enable User Workload Monitoring + Alertmanager (requires cluster-admin)
echo "Enabling User Workload Monitoring (cluster-admin required)..."
oc apply -f - <<'EOF' || true
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

# Wait for the user-workload namespace to exist
echo "Waiting for openshift-user-workload-monitoring namespace..."
for i in {1..30}; do
  if oc get ns openshift-user-workload-monitoring >/dev/null 2>&1; then break; fi
  sleep 5
done

# Enable user-workload Alertmanager specifically
echo "Enabling user-workload Alertmanager..."
oc apply -f - <<'EOF' || true
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    alertmanager:
      enabled: true
      enableAlertmanagerConfig: true
EOF

# Start binary builds
echo "Starting frontend build..."
oc start-build -n special-payment-project frontend --from-dir="$ROOT/frontend" --wait --follow
echo "Starting api build..."
oc start-build -n special-payment-project api --from-dir="$ROOT/api" --wait --follow
echo "Starting snow-bridge build..."
oc start-build -n special-monitoring snow-bridge --from-dir="$ROOT/monitoring/snow-bridge" --wait --follow

# Cleanup: remove build pods (noise)
echo "Cleaning up build pods..."
oc delete pod -n special-payment-project -l openshift.io/build.name --ignore-not-found || true

# Deployments + Services
oc apply -f "$ROOT/openshift/20-deploy-services.yaml"

# ExternalName service
oc apply -f "$ROOT/openshift/40-payments-external.yaml"

# Routes (patch host)
tmp=$(mktemp)
sed "s/special-payments.apps.CHANGE-ME.example.com/special-payments.$APPS_DOMAIN/g" "$ROOT/openshift/30-routes.yaml" > "$tmp"
oc apply -f "$tmp"
rm -f "$tmp"

# Monitoring (ServiceMonitor + PrometheusRule)
echo "Applying monitoring resources..."
oc apply -f "$ROOT/monitoring/servicemonitor.yaml"
oc apply -f "$ROOT/monitoring/prometheusrule.yaml"
# Optionally create/update ServiceNow credentials Secret from env
if [[ -n "${SERVICENOW_USERNAME:-}" && -n "${SERVICENOW_PASSWORD:-}" ]]; then
  echo "Ensuring snow-credentials Secret exists (from .env variables)..."
  oc -n special-monitoring create secret generic snow-credentials \
    --from-literal=username="${SERVICENOW_USERNAME}" \
    --from-literal=password="${SERVICENOW_PASSWORD}" \
    --dry-run=client -o yaml | oc apply -f -
fi
# Optionally create/update ServiceNow settings Secret (instance URL) from env
if [[ -n "${SERVICENOW_INSTANCE_URL:-}" ]]; then
  echo "Ensuring snow-settings Secret exists (from .env variables)..."
  oc -n special-monitoring create secret generic snow-settings \
    --from-literal=instance_url="${SERVICENOW_INSTANCE_URL}" \
    --dry-run=client -o yaml | oc apply -f -
fi
# Apply AlertmanagerConfig; if SERVICENOW_ALERT_WEBHOOK_URL provided, substitute placeholder
if [[ -f "$ROOT/monitoring/alertmanagerconfig.yaml" ]]; then
  if [[ -n "${SERVICENOW_ALERT_WEBHOOK_URL:-}" ]]; then
    echo "Applying AlertmanagerConfig with ServiceNow webhook URL from .env..."
    tmp_amc=$(mktemp)
    sed "s#https://YOUR_INSTANCE.service-now.com/api/YOUR_SCOPE/YOUR_API#${SERVICENOW_ALERT_WEBHOOK_URL}#g" \
      "$ROOT/monitoring/alertmanagerconfig.yaml" > "$tmp_amc"
    oc apply -f "$tmp_amc"
    rm -f "$tmp_amc"
  else
    echo "Applying AlertmanagerConfig (no SERVICENOW_ALERT_WEBHOOK_URL provided; using file as-is)..."
    oc apply -f "$ROOT/monitoring/alertmanagerconfig.yaml"
    echo "Tip: set SERVICENOW_ALERT_WEBHOOK_URL in $ROOT/.env to auto-substitute your endpoint."
  fi
else
  echo "Skipping AlertmanagerConfig (not found at $ROOT/monitoring/alertmanagerconfig.yaml)."
fi

# Wait for user-workload Alertmanager (if enabled)
echo "Waiting for user-workload Alertmanager to be ready..."
oc -n openshift-user-workload-monitoring rollout status statefulset/alertmanager-user-workload --timeout=300s || true

# Force rollouts to ensure latest images are pulled
echo "Forcing rollouts to pull latest images..."
oc -n special-payment-project rollout restart deploy/checkout-api || true
oc -n special-payment-project rollout restart deploy/checkout-frontend || true
oc -n special-monitoring rollout restart deploy/snow-bridge || true

echo "Waiting for rollouts..."
oc -n special-payment-project rollout status deploy/checkout-api --timeout=180s || true
oc -n special-payment-project rollout status deploy/checkout-frontend --timeout=180s || true
oc -n special-monitoring rollout status deploy/snow-bridge --timeout=180s || true

# Create a project-scoped automation ServiceAccount with token and display credentials
echo "Ensuring automation ServiceAccount and token exist..."
# Create/ensure project-scoped ServiceAccount in special-payment-project (idempotent)
oc -n special-payment-project create sa aap-automation --dry-run=client -o yaml | oc apply -f -
# Bind project edit role to the ServiceAccount (ignore if already bound)
oc -n special-payment-project adm policy add-role-to-user edit -z aap-automation >/dev/null 2>&1 || true
# Create/ensure a project-scoped token Secret annotated for the ServiceAccount (idempotent)
cat <<'EOF' | oc -n special-payment-project apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: aap-automation-token
  annotations:
    kubernetes.io/service-account.name: aap-automation
type: kubernetes.io/service-account-token
EOF
# Wait for token controller to populate the token data in the project namespace
echo "Waiting for automation token to be issued..."
for i in {1..30}; do
  token_b64="$(oc -n special-payment-project get secret aap-automation-token -o jsonpath='{.data.token}' 2>/dev/null || true)"
  if [[ -n "${token_b64}" ]]; then
    break
  fi
  sleep 2
done
# Decode and print token (if available)
if [[ -n "${token_b64:-}" ]]; then
  token_plain="$(echo -n "${token_b64}" | base64 -d 2>/dev/null || true)"
  echo
  echo "Automation credentials for downstream use:"
  echo "  ServiceAccount: aap-automation"
  echo "  Bearer Token: ${token_plain}"
  echo

  # If top-level .env exists, update/append OCP_API_TOKEN with the new token
  if [[ -f "$REPO_ROOT/.env" && -n "${token_plain}" ]]; then
    echo "Updating $REPO_ROOT/.env with OCP_API_TOKEN..."
    PYTHON_BIN="${PYTHON_BIN:-python3}"
    if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
      PYTHON_BIN=python
    fi
    if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
      echo "Warning: python/python3 not found; skipping .env update. Set PYTHON_BIN to your interpreter or install Python."
    else
      "$PYTHON_BIN" - "$REPO_ROOT/.env" "$token_plain" <<'PY'
import sys
from pathlib import Path

env_path = Path(sys.argv[1])
token = sys.argv[2]
lines = env_path.read_text().splitlines()
out = []
found = False
for line in lines:
    if line.startswith("OCP_API_TOKEN="):
        out.append(f"OCP_API_TOKEN={token}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"OCP_API_TOKEN={token}")
# Preserve trailing newline if the file had any content
trailing = "\n" if out else ""
env_path.write_text("\n".join(out) + trailing)
PY
    fi
  fi
else
  echo "Warning: token not yet available on Secret aap-automation-token. Try again shortly:"
  echo "  oc -n special-payment-project get secret aap-automation-token -o jsonpath='{.data.token}' | base64 -d; echo"
fi

echo
echo "Open the site:"
echo "  https://special-payments.$APPS_DOMAIN"
echo
echo "Click 'Pay £1.00' — should succeed (200)."
echo
echo "Observability:"
echo "- In the OpenShift Console -> Developer or Admin perspective -> Observe -> Metrics:"
echo "  Query: special_project_upstream_ok (namespace: special-payment-project)"
echo "- Observe -> Alerts: look for 'PaymentUpstream' when the upstream is down."
echo "- To monitor alerts locally via Thanos Ruler:"
echo "  Run: oc -n openshift-user-workload-monitoring port-forward svc/thanos-ruler-operated 10902:10902"
echo "  Then open: http://localhost:10902/alerts"


