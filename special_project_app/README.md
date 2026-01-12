Special Payment Project (OpenShift demo)
=======================================

A tiny app to demonstrate OpenShift Routes, Binary BuildConfigs/ImageStreams, and a DNS failure via an ExternalName Service. The frontend calls the API at `/api/checkout`, which calls an upstream via `payments-external` (ExternalName). If the ExternalName is typo’d (NXDOMAIN), the API returns HTTP 502 and the UI shows a visible error — “it’s always DNS”.

What’s here
-----------
- frontend: Static site (nginx unprivileged, port 8080)
- api: FastAPI + Uvicorn (port 8000)
- openshift: Namespace, ImageStreams/BuildConfigs, Deployments/Services, Routes, ExternalName
- scripts: Helper scripts for deploy and DNS break/restore
 
Documentation (generic, realistic for AIOps/RAG)
------------------------------------------------
- `docs/architecture-overview.md` — components, request flow, and config surface
- `docs/deployment-and-configuration.md` — setup, routes, env vars, upstream choices
- `docs/operations-runbook.md` — routine checks, scaling, rollouts, smoke tests
- `docs/troubleshooting-guide.md` — symptom-based diagnostics without assuming root cause
- `docs/incident-response-playbook.md` — triage, comms, mitigation, and verification
- `docs/networking-and-dns.md` — generic DNS/Service guidance (no environment-specific values)

Prerequisites
-------------
- `oc` CLI
- Logged in to an OpenShift cluster with permissions to create in a new namespace
- The cluster’s apps wildcard domain (e.g. `apps.cluster-xxxx.example.com`)

Deploy
------
1) From this directory, run:
```bash
./scripts/oc-deploy.sh <APPS_DOMAIN>
# example:
./scripts/oc-deploy.sh apps.cluster-xxxx.example.com
```
This will:
- Create namespace `special-project`
- Apply ImageStreams/BuildConfigs
- Start binary builds from local `frontend/` and `api/`
- Deploy `frontend` and `api`
- Create the ExternalName service: `payments-external -> httpbin.org`
- Create two Routes on the same host:
  - `/` → frontend
  - `/api` → api

2) Open the site:
```bash
https://special-payments.<APPS_DOMAIN>
```
Click “Pay £1.00” — should return success (HTTP 200).

Break DNS (demo the 502)
------------------------
```bash
./scripts/break_dns.sh
```
This patches `payments-external` to `httpbn.org` (typo → NXDOMAIN). Refresh the site and click Pay — the API returns 502 with the DNS error text, and the UI shows “Payment failed: HTTP 502”.

Restore DNS
-----------
```bash
./scripts/restore_dns.sh
```
This restores `payments-external` to `httpbin.org`. Refresh and click Pay — it should succeed (HTTP 200).

Notes
-----
- Containers are OpenShift-friendly: `nginxinc/nginx-unprivileged` for the frontend; the API runs fine with random UID (no write-at-runtime paths).
- The two Routes share the same host; the frontend JavaScript calls `/api/checkout` relative to that host.


Diagnostics playbook (optional)
-------------------------------
- A simple, generic diagnostics playbook is available at `playbooks/diagnostics.yml`.
- Example usage:
```bash
ansible-playbook -i localhost, playbooks/diagnostics.yml -e namespace=special-payment-project
```
It gathers Routes, Deployments, Services, Endpoints, Pods, extracts the API’s upstream configuration, and (if possible) runs basic DNS and HTTP checks from inside an API pod, printing a concise summary for AIOps agents.


Thanos UI (user workload monitoring)
------------------------------------
To open the Thanos Ruler UI locally, port-forward the service from the user-workload monitoring namespace:
```bash
oc -n openshift-user-workload-monitoring port-forward svc/thanos-ruler-operated 10902:10902
```
Then visit:
```bash
http://localhost:10902/
```

