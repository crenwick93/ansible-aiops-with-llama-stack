# Troubleshooting Guide

Use this guide when symptoms are present but the root cause is unknown. It provides symptom-based checks and safe diagnostics without assuming a specific failure (e.g., DNS, routing, or upstream issues).

## Symptom: API returns HTTP 502 to clients
Likely causes:
- Upstream returned 5xx
- Upstream not reachable (DNS, network, or timeout)
- Misconfigured upstream URL

Diagnostics:
```bash
# Check recent logs for the API
oc -n <NAMESPACE> logs deploy/api --tail=200

# Verify API can resolve the upstream Service name
oc -n <NAMESPACE> exec deploy/api -- getent hosts <UPSTREAM_SERVICE_FQDN> || echo "resolution failed"

# Curl upstream from inside API pod (adjust scheme/port/path)
oc -n <NAMESPACE> exec deploy/api -- curl -i -m 5 <UPSTREAM_URL>
```
If resolution fails, inspect the Service resource:
```bash
oc -n <NAMESPACE> get svc <SERVICE_NAME> -o yaml
```
- For an ExternalName Service: verify the `spec.externalName` points to a valid FQDN
- For a ClusterIP Service: verify backing Endpoints exist and Pods are Ready

## Symptom: Route not reachable or returns 404
Diagnostics:
```bash
oc -n <NAMESPACE> get route
oc -n <NAMESPACE> describe route portal-frontend
oc -n <NAMESPACE> describe route portal-api
```
Checks:
- `spec.host` matches `special-payments.<APPS_DOMAIN>`
- For the API Route, `spec.path: /api` is present
- TLS termination mode matches cluster expectations (edge/passthrough/re-encrypt)

## Symptom: API pod CrashLoopBackOff
Diagnostics:
```bash
oc -n <NAMESPACE> get pods
oc -n <NAMESPACE> describe pod <POD_NAME>
oc -n <NAMESPACE> logs <POD_NAME> --previous
```
Checks:
- Environment variables are present and valid
- Container image pulls successfully
- No port conflicts or readiness probe failures

## Symptom: Build failures (frontend or API)
Diagnostics:
```bash
oc -n <NAMESPACE> get bc,build
oc -n <NAMESPACE> logs bc/frontend
oc -n <NAMESPACE> logs bc/api
```
Checks:
- Binary context path passed to `start-build` is correct
- Containerfile paths are correct (`Containerfile`)
- The internal registry is reachable

## Symptom: Timeouts or latency regressions
Diagnostics:
```bash
oc -n <NAMESPACE> logs deploy/api --tail=200
```
Checks:
- `HTTP_TIMEOUT` sufficiently high for upstream behavior
- Upstream target responsive from inside cluster
- Resource pressure (CPU/memory throttling) on API pods

## Quick verification after changes
```bash
curl -i https://special-payments.<APPS_DOMAIN>/api/ping-upstream
curl -i -X POST https://special-payments.<APPS_DOMAIN>/api/checkout
```



