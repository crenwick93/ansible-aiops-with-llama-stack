from fastapi import FastAPI, Response, status
import os, socket, httpx, time, logging, asyncio
from prometheus_client import Gauge, CONTENT_TYPE_LATEST, generate_latest

app = FastAPI(title="Special Payment Project API")

PAYMENTS_BASE = os.getenv("PAYMENTS_BASE", "http://payments-external.special-payment-project.svc.cluster.local:5678")
PAYMENTS_PATH = os.getenv("PAYMENTS_PATH", "")
TIMEOUT = float(os.getenv("HTTP_TIMEOUT", "5.0"))
PING_INTERVAL = float(os.getenv("UPSTREAM_PING_INTERVAL", "15"))
logger = logging.getLogger("special-payment-project.api")

# Prometheus metrics
UPSTREAM_OK = Gauge("special_project_upstream_ok", "1 if payments upstream reachable, else 0")
UPSTREAM_LATENCY_SECONDS = Gauge("special_project_upstream_latency_seconds", "Last upstream ping latency in seconds")

@app.get("/health")
def health():
    return {"ok": True, "hostname": socket.gethostname()}

@app.post("/api/checkout")
async def checkout():
    url = f"{PAYMENTS_BASE}{PAYMENTS_PATH}"
    t0 = time.time()
    logger.info("checkout start url=%s timeout=%ss", url, TIMEOUT)
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT, verify=False) as client:
            r = await client.get(url)
        elapsed = round(time.time() - t0, 3)
        if r.status_code == 200:
            logger.info("checkout upstream_ok status=%s url=%s elapsed_s=%s", r.status_code, url, elapsed)
            # update metrics on successful upstream call
            UPSTREAM_OK.set(1)
            UPSTREAM_LATENCY_SECONDS.set(elapsed)
            return {"status": "OK", "payments_url": url, "upstream_status": r.status_code, "elapsed_s": elapsed}
        else:
            logger.warning("checkout upstream_bad status=%s url=%s elapsed_s=%s", r.status_code, url, elapsed)
            # update metrics on bad upstream status
            UPSTREAM_OK.set(0)
            UPSTREAM_LATENCY_SECONDS.set(elapsed)
            return Response(
                content=f"Upstream responded {r.status_code} from {url} in {elapsed}s",
                status_code=status.HTTP_502_BAD_GATEWAY,
                media_type="text/plain",
            )
    except httpx.RequestError as e:
        elapsed = round(time.time() - t0, 3)
        logger.error("checkout upstream_error url=%s err=%s elapsed_s=%s", url, f"{e.__class__.__name__}: {e}", elapsed)
        # update metrics on request error
        UPSTREAM_OK.set(0)
        UPSTREAM_LATENCY_SECONDS.set(elapsed)
        return Response(
            content=f"Exception contacting payments upstream {url}: {e.__class__.__name__}: {e} (elapsed {elapsed}s)",
            status_code=status.HTTP_502_BAD_GATEWAY,
            media_type="text/plain",
        )

@app.get("/api/ping-upstream")
async def ping_upstream():
    # Same upstream call as /api/checkout, but exposed via GET for monitoring
    return await checkout()

@app.get("/metrics")
def metrics():
    # Expose Prometheus metrics for scraping
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

async def _periodic_upstream_probe():
    # Background task to actively probe the upstream and update metrics periodically
    while True:
        url = f"{PAYMENTS_BASE}{PAYMENTS_PATH}"
        t0 = time.time()
        ok = 0
        try:
            async with httpx.AsyncClient(timeout=TIMEOUT, verify=False) as client:
                r = await client.get(url)
            ok = 1 if r.status_code == 200 else 0
        except httpx.RequestError:
            ok = 0
        elapsed = round(time.time() - t0, 3)
        UPSTREAM_OK.set(ok)
        UPSTREAM_LATENCY_SECONDS.set(elapsed)
        await asyncio.sleep(PING_INTERVAL)

@app.on_event("startup")
async def _on_startup():
    # Start background probe task
    asyncio.create_task(_periodic_upstream_probe())


