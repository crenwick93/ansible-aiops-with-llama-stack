from fastapi import FastAPI, Request, Response, status
import os, logging
import requests

app = FastAPI(title="Alertmanager → ServiceNow Bridge")
logger = logging.getLogger("snow-bridge")
logging.basicConfig(level=logging.INFO)

SERVICENOW_INSTANCE_URL = os.getenv("SERVICENOW_INSTANCE_URL", "").rstrip("/")
SERVICENOW_USERNAME = os.getenv("SERVICENOW_USERNAME", "")
SERVICENOW_PASSWORD = os.getenv("SERVICENOW_PASSWORD", "")


def _build_incident_payload(alert: dict) -> dict:
    labels = alert.get("labels", {}) or {}
    annotations = alert.get("annotations", {}) or {}
    summary = annotations.get("summary") or labels.get("alertname") or "Alert"
    description_lines = []
    if annotations.get("description"):
        description_lines.append(annotations["description"])
    namespace = labels.get("namespace")
    if namespace:
        description_lines.append(f"Namespace: {namespace}")
    description = "\n".join([line for line in description_lines if line])

    # Map severity to SNOW values (1 critical, 2 high, 3 moderate, 4 low, 5 planning)
    sev_label = (labels.get("severity") or "").lower()
    severity_map = {"critical": "1", "warning": "2", "info": "3"}
    snow_severity = severity_map.get(sev_label, "3")

    payload = {
        "short_description": summary,
        "description": description,
        "severity": snow_severity,
        "urgency": snow_severity,
        "impact": snow_severity,
        # Add any static routing if desired:
        # "assignment_group": "Your Support Group",
        # "category": "Infrastructure",
        # "subcategory": "Monitoring",
    }
    return payload

def _compute_correlation_id(alert: dict) -> str:
    labels = alert.get("labels", {}) or {}
    # Keep correlation_id stable for the same alert dimension to dedupe repeat notifications
    alertname = labels.get("alertname") or "Alert"
    namespace = labels.get("namespace") or "default"
    # Extend with other labels if you want finer granularity
    return f"{namespace}:{alertname}"

def _incident_exists(correlation_id: str) -> bool:
    url = f"{SERVICENOW_INSTANCE_URL}/api/now/table/incident"
    params = {
        "sysparm_query": f"correlation_id={correlation_id}^state!=7",  # 7 = Closed
        "sysparm_fields": "sys_id,number,state",
        "sysparm_limit": "1",
    }
    try:
        r = requests.get(url, params=params, auth=(SERVICENOW_USERNAME, SERVICENOW_PASSWORD), timeout=10)
        if r.status_code // 100 != 2:
            logger.warning("ServiceNow query failed status=%s body=%s", r.status_code, r.text[:200])
            return False
        data = r.json() or {}
        result = data.get("result") or []
        return len(result) > 0
    except requests.RequestException as e:
        logger.error("Error querying ServiceNow for correlation_id=%s: %s", correlation_id, e)
        return False


@app.post("/alerts")
async def alerts(req: Request):
    if not (SERVICENOW_INSTANCE_URL and SERVICENOW_USERNAME and SERVICENOW_PASSWORD):
        return Response(
            content="ServiceNow configuration missing",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            media_type="text/plain",
        )
    data = await req.json()
    logger.info("Received Alertmanager webhook: status=%s alerts=%s", data.get("status"), len(data.get("alerts") or []))
    status_str = data.get("status")
    alerts = data.get("alerts") or []

    # Only act on firing alerts for demo; sendResolved true is configured if you need to handle resolutions
    created = 0
    errors = []
    for alert in alerts:
        if (alert.get("status") or "").lower() != "firing":
            continue
        correlation_id = _compute_correlation_id(alert)
        if _incident_exists(correlation_id):
            logger.info("Skipping create; incident with correlation_id=%s already exists", correlation_id)
            continue
        payload = _build_incident_payload(alert)
        payload["correlation_id"] = correlation_id
        url = f"{SERVICENOW_INSTANCE_URL}/api/now/table/incident"
        try:
            r = requests.post(
                url,
                json=payload,
                auth=(SERVICENOW_USERNAME, SERVICENOW_PASSWORD),
                timeout=10,
            )
            if r.status_code // 100 == 2:
                logger.info("ServiceNow incident created (status=%s)", r.status_code)
                created += 1
            else:
                msg = f"{r.status_code} {r.text[:200]}"
                logger.warning("ServiceNow incident create failed: %s", msg)
                errors.append(msg)
        except requests.RequestException as e:
            logger.error("Error calling ServiceNow: %s", e)
            errors.append(str(e))

    if errors:
        return Response(
            content=f"Created {created} incidents; errors: {errors}",
            status_code=status.HTTP_207_MULTI_STATUS,
            media_type="text/plain",
        )
    return {"ok": True, "created": created, "status": status_str}


