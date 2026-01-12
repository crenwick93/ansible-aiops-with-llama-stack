# Special Payment Project — Architecture Overview

Purpose: Give engineers and operators a clear understanding of how the demo application is composed, how requests flow, and which parts are configurable. This document is intentionally generic so it remains useful even when the specific incident is unknown.

## High-level components
- Frontend
  - Static site served by an unprivileged nginx image on port 8080
  - Calls backend relative path `/api/checkout`
- API
  - FastAPI + Uvicorn, listens on port 8000
  - Calls a payments upstream over HTTP(S)
  - Configurable via environment variables:
    - `PAYMENTS_BASE`: base URL to the upstream (required)
    - `PAYMENTS_PATH`: optional path suffix
    - `HTTP_TIMEOUT`: timeout (seconds) for upstream requests
- Payments upstream
  - Reached via a Kubernetes Service name
  - In this demo, exposed using a `Service` with `type: ExternalName` or an in-cluster mock Service

## Network and routing
- OpenShift Routes
  - A single hostname (e.g., `special-payments.<APPS_DOMAIN>`) is used for the app
  - Two Routes share the same host:
    - `/` → `Service/frontend` (port 8080)
    - `/api` → `Service/api` (port 8000)
- Service-to-Service
  - API resolves and calls the upstream using the Service DNS name
  - In-cluster DNS provides `*.svc.cluster.local` resolution

## Build and deployment model
- ImageStreams + Binary BuildConfigs for `frontend` and `api`
- Deployments:
  - `frontend` replicas >= 1 (defaults to 2)
  - `api` replicas >= 1 (defaults to 2)
- Services expose Pods internally
- Routes expose Services externally

## Observability endpoints
- `GET /health`
  - Simple readiness probe for API container
- `GET /api/ping-upstream`
  - Mirrors the upstream call made by `/api/checkout`
  - Useful for synthetic monitoring and diagnostics

## Security and platform considerations
- Containers run as random, non-root UIDs compatible with OpenShift SCC defaults
- No runtime writes to the container filesystem required
- TLS termination is typically handled at the Route (edge TLS); adjust as needed

## Configuration surface (summary)
- Route host: `special-payments.<APPS_DOMAIN>`
- Namespace: `<NAMESPACE>` (defaults to `special-payment-project` in examples)
- API environment:
  - `PAYMENTS_BASE`, `PAYMENTS_PATH`, `HTTP_TIMEOUT`
- Upstream Service:
  - May be defined as a regular ClusterIP Service (backed by Pods) or an `ExternalName` alias to a target outside the namespace/cluster

## Request flow
1) User hits `https://special-payments.<APPS_DOMAIN>/`
2) Frontend JavaScript calls `POST /api/checkout`
3) API builds the upstream URL from environment config
4) API requests upstream; success is returned as 200 to client, otherwise a 502 is surfaced with a short diagnostic string



