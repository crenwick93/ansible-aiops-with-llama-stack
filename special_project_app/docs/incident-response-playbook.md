# Incident Response Playbook

This playbook defines a consistent response to production-impacting issues, regardless of root cause. Adapt severity, comms, and actions to your environment.

## Roles and communication
- Incident Commander (IC): coordinates response
- Tech Lead (TL): directs diagnostics and mitigations
- Comms Lead: stakeholder and status updates
- Channels: incident chat room, ticketing system, status page (if applicable)

## Severity guidance (example)
- SEV-1: Full outage or critical user impact
- SEV-2: Degraded service with partial user impact
- SEV-3: Minor impact or at-risk indicators

## Initial triage (first 5–10 minutes)
1) Acknowledge and page on-call roles
2) Capture symptoms and scope (which endpoints/users/regions)
3) Freeze risky changes if necessary
4) Start incident ticket and timeline

## Diagnostics checklist
- External health:
  - Route availability for `/` and `/api`
  - Synthetic probe to `/api/ping-upstream`
- Internal state:
  - API logs for upstream errors or timeouts
  - Service/Endpoints health for upstream target
  - DNS resolution from API pod to upstream Service
- Recent changes:
  - Image rollouts, config or secret changes, route edits

## Mitigation options
- Rollback the last deployment (`oc rollout undo deploy/api`)
- Scale out API temporarily if resource constrained
- Adjust `HTTP_TIMEOUT` if superficial timeouts are observed (with caution)
- Switch upstream to a known-good alternative (mock or fallback) if supported

## Verification
- Re-run smoke tests:
  - `GET /api/health`
  - `GET /api/ping-upstream`
  - `POST /api/checkout` (synthetic or safe test)
- Confirm user-facing errors are resolved and error rates return to baseline

## Closure
- Document root cause (if known), contributing factors, and mitigations
- Capture follow-ups (observability, tests, config guardrails)
- Communicate resolution and update ticket



