# Deployment & Configuration

## 1. Overview

This is a simplified, simulated guide to how the Special Payment Project is deployed and configured. It is intended for debugging and triage context only, not as an authoritative runbook. Exact steps and commands vary by environment and are intentionally omitted.

## 2. What Gets Deployed (at a glance)

- `checkout-frontend` (ClusterIP Service, port 8080)
  - Exposed via a Route like `https://special-payment.<apps-domain>`
  - Serves the UI and calls the backend at `/api/checkout`

- `checkout-api` (ClusterIP Service, port 8000)
  - FastAPI service that validates requests and calls the gateway
  - Uses `PAYMENTS_BASE` to reach the gateway alias

- `card-gateway-dns` (Service of type ExternalName)
  - Lives in `special-payment-project`
  - Stable in-cluster alias the API calls (e.g., `http://card-gateway-dns:5678`)
  - Points to the canonical gateway FQDN documented in Networking & External Dependencies

- `card-gateway-sandbox` (ClusterIP Service, port 5678)
  - Lives in `payments-provider-sim`
  - Simulated payment gateway responding with deterministic results

## 3. How It Usually Gets There

- Applied via GitOps or a lightweight CI/CD pipeline
- Namespaces, Deployments, Services, and Routes are created by manifests
- Monitoring/alerts may be enabled, but details differ per cluster

## 4. Key Configuration Knobs (useful for debugging)

- `checkout-frontend`
  - API base path generally `/api`; Route should forward `/api/checkout` to the backend

- `checkout-api`
  - `PAYMENTS_BASE` should point to the in-cluster alias: `http://card-gateway-dns:5678`
  - Optional timeouts/retries control behavior on slow or failing upstreams

- `card-gateway-dns` (ExternalName)
  - Must have `spec.type: ExternalName`
  - `spec.externalName` should match the canonical gateway FQDN referenced in the Networking & External Dependencies doc (source of truth)

- `card-gateway-sandbox`
  - Typically serves on port 5678 in `payments-provider-sim`

## 5. Common Misconfigurations

- `PAYMENTS_BASE` in the API points to a wrong hostname or port
- `card-gateway-dns` not `ExternalName`, or `externalName` value is misspelled
- Route does not forward `/api` to the API service as expected
- Gateway service missing or running in a different namespace/port than assumed

## 6. Related Documents

- Overview & Context
- Application Architecture
- Networking & External Dependencies
- Observability & Alerts


