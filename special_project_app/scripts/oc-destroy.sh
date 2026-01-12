#!/usr/bin/env bash
set -euo pipefail

# Destroys resources created by scripts/oc-deploy.sh
# - Deletes project-scoped namespaces:
#     special-payment-project, payments-provider-sim, special-monitoring
# - Attempts to remove user-workload and cluster monitoring configmaps
#   (requires cluster-admin, errors ignored)
#
# Usage: ./scripts/oc-destroy.sh

echo "Starting teardown of Special Project App resources..."

# Best-effort removal of monitoring ConfigMaps (cluster-admin required)
echo "Removing monitoring ConfigMaps (best-effort; requires cluster-admin)..."
oc -n openshift-user-workload-monitoring delete configmap user-workload-monitoring-config --ignore-not-found || true
oc -n openshift-monitoring delete configmap cluster-monitoring-config --ignore-not-found || true

# Remove role binding for project-scoped automation SA (best-effort)
echo "Removing project edit role from ServiceAccount aap-automation (best-effort)..."
oc -n special-payment-project adm policy remove-role-from-user edit -z aap-automation >/dev/null 2>&1 || true

# Delete namespaces created by deploy (removes all contained resources)
for ns in special-payment-project payments-provider-sim special-monitoring; do
  echo "Deleting namespace: ${ns} (if exists)..."
  oc delete namespace "${ns}" --ignore-not-found
done

echo "Teardown requested. Namespace deletions may take a while to fully complete."
echo "You can watch progress with: oc get ns | egrep 'special-payment-project|payments-provider-sim|special-monitoring'"


