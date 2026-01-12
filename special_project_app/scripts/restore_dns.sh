#!/usr/bin/env bash
set -euo pipefail
echo "Restoring DNS for card-gateway-dns..."
oc patch service -n special-payment-project card-gateway-dns \
  --type=merge -p '{"spec":{"externalName":"card-gateway-sandbox.payments-provider-sim.svc.cluster.local"}}'
oc get svc -n special-payment-project card-gateway-dns -o yaml | sed -n '1,20p'
echo "Now refresh and click Pay — should be OK (HTTP 200)."


