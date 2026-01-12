# Operations Runbook

This runbook outlines routine checks, safe day-2 operations, and verification steps for the app. Use this document as a baseline regardless of the specific failure mode.

## Health and smoke tests
- API health:
```bash
curl -s https://special-payments.<APPS_DOMAIN>/api/health || curl -s http://<ROUTE_HOST>/api/health
```
- Smoke test upstream path (read-only):
```bash
curl -i https://special-payments.<APPS_DOMAIN>/api/ping-upstream
```
- End-to-end UI:
  - Load `https://special-payments.<APPS_DOMAIN>/`
  - Click “Pay £1.00” and confirm a 200 response is shown

## Scaling and rollouts
- Scale deployments:
```bash
oc -n <NAMESPACE> scale deploy/frontend --replicas=3
oc -n <NAMESPACE> scale deploy/api --replicas=3
```
- Rolling restart:
```bash
oc -n <NAMESPACE> rollout restart deploy/api
oc -n <NAMESPACE> rollout status deploy/api
```
- Rolling back:
```bash
oc -n <NAMESPACE> rollout undo deploy/api
```

## Builds and image updates
- Rebuild from local sources (binary builds):
```bash
oc -n <NAMESPACE> start-build frontend --from-dir=frontend --follow
oc -n <NAMESPACE> start-build api --from-dir=api --follow
```
- Verify deployment picked up new image:
```bash
oc -n <NAMESPACE> rollout status deploy/frontend
oc -n <NAMESPACE> rollout status deploy/api
```

## Route verification
```bash
oc -n <NAMESPACE> get route
oc -n <NAMESPACE> describe route portal-frontend
oc -n <NAMESPACE> describe route portal-api
```
Ensure hosts and paths match expectations and TLS termination is as intended.

## Logging and basic triage
```bash
oc -n <NAMESPACE> logs deploy/api --tail=200
oc -n <NAMESPACE> logs deploy/frontend --tail=200
```
- Look for upstream timeouts, 5xx from upstream, connection errors, or path mismatches
- Check pod events for restarts:
```bash
oc -n <NAMESPACE> get pods
oc -n <NAMESPACE> describe pod <POD_NAME>
```

## Monitoring suggestions
- Synthetic probe against `/api/ping-upstream`
- Alert on sustained 5xx from API Route
- Track p95 latency and error rate for `/api/checkout`



