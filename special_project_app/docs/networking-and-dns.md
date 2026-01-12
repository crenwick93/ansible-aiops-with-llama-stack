# Networking and DNS Considerations

This guide explains how the application uses Kubernetes Services and DNS, and provides generic diagnostics for name resolution and connectivity issues. It avoids encoding any specific known-bad values so it remains realistic for incident response.

## Service models used
- ClusterIP Service (backed by Pods and Endpoints)
- ExternalName Service (DNS CNAME-like alias that points at an external FQDN)

The API constructs an upstream URL from environment variables and performs HTTP(S) requests to it. The target is commonly reached via a Service DNS name within the cluster.

## Common failure modes
- Name resolution failure for the upstream Service or external FQDN
- ExternalName target FQDN is incorrect or not resolvable from the cluster
- ClusterIP Service has no ready Endpoints
- Network egress restrictions or TLS issues

## Generic diagnostics
From inside the API pod:
```bash
# Check DNS resolution
oc -n <NAMESPACE> exec deploy/api -- getent hosts <UPSTREAM_SERVICE_FQDN> || echo "resolution failed"

# Check HTTP reachability (adjust scheme/port/path)
oc -n <NAMESPACE> exec deploy/api -- curl -i -m 5 <UPSTREAM_URL>
```
Inspect the Service:
```bash
oc -n <NAMESPACE> get svc <SERVICE_NAME> -o yaml
```
Interpretation:
- If `type: ExternalName`, verify `spec.externalName` points to a valid FQDN that your cluster can resolve
- If `type: ClusterIP`, verify `Endpoints` exist and Pods are Ready:
```bash
oc -n <NAMESPACE> get endpoints <SERVICE_NAME> -o wide
```

## Configuration guardrails (recommended)
- Validate Service changes in CI (lint `spec.externalName` or ensure Endpoints exist before rollout)
- Avoid hard-coding environment-specific hostnames in application code; prefer environment variables or ConfigMaps/Secrets
- Monitor `GET /api/ping-upstream` and alert on sustained failures

## Safe remediation template
(Adapt the below to your environment and change-management process.)
```bash
# Option A: Fix ExternalName target
oc -n <NAMESPACE> patch svc <SERVICE_NAME> \
  --type=merge -p '{"spec":{"externalName":"<VALID_TARGET_FQDN>"}}'

# Option B: Point API to an in-cluster mock or fallback
oc -n <NAMESPACE> set env deploy/api PAYMENTS_BASE=http://<CLUSTER_SERVICE_FQDN>:<PORT>
oc -n <NAMESPACE> rollout restart deploy/api
```



