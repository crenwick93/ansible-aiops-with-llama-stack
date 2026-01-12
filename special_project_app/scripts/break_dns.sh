#!/usr/bin/env bash
set -euo pipefail
echo "Breaking DNS for card-gateway-dns (typo -> NXDOMAIN)..."
oc patch service -n special-payment-project card-gateway-dns \
  --type=merge -p '{"spec":{"externalName":"card-gateway-sandbx.payments-provider-sim.svc.cluster.local"}}'
oc get svc -n special-payment-project card-gateway-dns -o yaml | sed -n '1,20p'
echo "Now refresh checkout and click Pay — expect HTTP 502 with DNS error text."


