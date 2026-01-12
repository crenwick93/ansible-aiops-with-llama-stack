import os
import sys
import time
import re
from typing import List, Optional, Generator

import requests
from markdownify import markdownify as html2md

# ------------------- Simple logging -------------------
LEVELS = {"DEBUG": 10, "INFO": 20, "WARN": 30, "ERROR": 40}
LOG_LEVEL = LEVELS.get(os.getenv("LOG_LEVEL", "INFO").upper(), 20)
ts = lambda: time.strftime("%Y-%m-%dT%H:%M:%S")
def log(level: str, msg: str):
    if LEVELS[level] >= LOG_LEVEL:
        print(f"[{ts()}] {level:5s} | {msg}")
def info(m): log("INFO", m)
def debug(m): log("DEBUG", m)
def warn(m): log("WARN", m)
def error(m): log("ERROR", m)

# ------------------- Llama Stack SDK -------------------
try:
    from llama_stack_client import LlamaStackClient
    from llama_stack_client.types import Document
except Exception:
    print("Install dependency: pip install llama-stack-client", file=sys.stderr)
    raise

# ------------------- Small helpers -------------------

 

def conf_session(user: str, token: str) -> requests.Session:
    s = requests.Session()
    s.auth = (user, token)
    s.headers.update({"Accept": "application/json"})
    return s

def resolve_space_key_by_name(session: requests.Session, cloud_id: str, space_name: str) -> Optional[str]:
    base = f"https://api.atlassian.com/ex/confluence/{cloud_id}/wiki/rest/api"
    url = f"{base}/space"
    start = 0
    while True:
        r = session.get(url, params={"start": start, "limit": 50}, timeout=60)
        r.raise_for_status()
        results = r.json().get("results", [])
        for sp in results:
            if str(sp.get("name", "")).strip().lower() == space_name.strip().lower():
                return sp.get("key")
        if len(results) < 50: break
        start += len(results)
    return None

def build_cql(space_key: str, labels: List[str], since_hours: int) -> str:
    parts = ["type=page"]
    if since_hours > 0: parts.append(f'lastmodified > now("-{since_hours}h")')
    if space_key: parts.append(f'space="{space_key}"')
    if labels: parts.append("(" + " OR ".join([f'label="{l}"' for l in labels]) + ")")
    return " and ".join(parts)

def conf_search_pages(session: requests.Session, cloud_id: str, cql: str, limit: int = 50) -> Generator[dict, None, None]:
    base = f"https://api.atlassian.com/ex/confluence/{cloud_id}/wiki/rest/api"
    url = f"{base}/content/search"
    start = 0
    while True:
        r = session.get(
            url,
            params={
                "cql": cql,
                "limit": limit,
                "start": start,
                "expand": "body.export_view,version,metadata.labels,space,history.lastUpdated",
            },
            timeout=60,
        )
        r.raise_for_status()
        results = r.json().get("results", [])
        if not results: break
        for item in results: yield item
        if len(results) < limit: break
        start += len(results)

def html_to_markdown(html: str) -> str:
    md = html2md(html or "", strip=["script", "style"])
    md = re.sub(r"\s+\n", "\n", md)
    md = re.sub(r"\n{3,}", "\n\n", md)
    return md.strip()


def verify_vector_store(llama_base_url: str, vdb_id: str, timeout: int = 60) -> bool:
    """Fetch vector store files and ensure they completed."""
    url = f"{llama_base_url}/v1/vector_stores/{vdb_id}/files"
    try:
        resp = requests.get(url, timeout=timeout)
        resp.raise_for_status()
    except Exception as exc:
        error(f"Vector store verification failed to reach {url}: {exc}")
        return False

    payload = resp.json()
    files = payload.get("data", [])
    failed = [f for f in files if f.get("status") not in ("completed", "Complete", "succeeded", "Succeeded")]

    info(f"Vector store file status: total={len(files)}, failed={len(failed)}")
    if failed:
        error("Failed vector store files detected:")
        for f in failed:
            fid = f.get("id")
            status = f.get("status")
            last_err = f.get("last_error")
            title = ((f.get("attributes") or {}).get("title")) or ""
            error(f"  id={fid} status={status} title={title} last_error={last_err}")
        return False
    return True

# ------------------- Main -------------------
def main() -> int:
    llama_base_url = os.getenv("LLAMA_BASE_URL", "http://lsd-llama-milvus-inline-service.default.svc.cluster.local:8321").rstrip("/")
    conf_cloud_id = os.getenv("CONF_CLOUD_ID", "").strip()
    conf_user = os.getenv("CONF_USER", "").strip()
    conf_api_token = os.getenv("CONF_API_TOKEN", "").strip()
    space_name = os.getenv("SPACE_NAME", "").strip()
    labels = [s.strip() for s in os.getenv("LABELS", "").split(",") if s.strip()]
    since_hours = int(os.getenv("SINCE_HOURS", "0") or 0)
    vector_db_name = os.getenv("VECTOR_DB_ID", "confluence").strip()
    batch_size = int(os.getenv("BATCH_SIZE", "100") or 100)

    missing = [n for n, v in [("CONF_CLOUD_ID", conf_cloud_id), ("CONF_USER", conf_user), ("CONF_API_TOKEN", conf_api_token), ("SPACE_NAME", space_name)] if not v]
    if missing:
        error("Missing env: " + ", ".join(missing)); return 2

    info(f"LLAMA_BASE_URL: {llama_base_url}")
    info(f"VECTOR_DB_ID:   {vector_db_name}")
    info(f"SPACE_NAME:     {space_name}")

    # Connect
    info("Connecting to Llama Stack...")
    timeout_seconds = float(os.getenv("LLAMA_TIMEOUT_SECONDS", "180") or 180)
    client = LlamaStackClient(base_url=llama_base_url, timeout=timeout_seconds)

    # Validate vector store id (0.3.x expects a concrete vs_* id)
    info("Selecting embedding model...")
    embed_model = next(m for m in client.models.list() if m.model_type == "embedding")
    info(f"Using embedding model: {embed_model.identifier}")
    if vector_db_name.startswith("vs_"):
        vdb_id = vector_db_name
    else:
        error("VECTOR_DB_ID must be a concrete vector store id (e.g., vs_...). See README to pre-create one and set it in .env.")
        return 2

    # Confluence ingest
    info("Creating Confluence session...")
    session = conf_session(conf_user, conf_api_token)
    info(f"Resolving space key for '{space_name}'...")
    space_key = resolve_space_key_by_name(session, conf_cloud_id, space_name)
    if not space_key:
        error(f"Space '{space_name}' not found or no access."); return 3
    info(f"SPACE_KEY: {space_key}")

    cql = build_cql(space_key, labels, since_hours)
    info(f"CQL: {cql}")
    info(f"BATCH_SIZE: {batch_size}")

    documents: List[Document] = []
    prepared = inserted = 0
    first_title: Optional[str] = None

    info("Fetching Confluence pages...")
    for page in conf_search_pages(session, conf_cloud_id, cql):
        page_id = page.get("id"); title = page.get("title", "")
        body_html = (((page.get("body") or {}).get("export_view") or {}).get("value")) or ""
        md = html_to_markdown(body_html)
        if not md: continue
        md_body = md or ""
        md_with_title = f"# {title}\n\n{md_body}".strip()
        doc = Document(
            document_id=f"conf-{page_id}",
            content=md_with_title,
            mime_type="text/markdown",
            metadata={
                "source": "confluence",
                "source_url": f"https://api.atlassian.com/ex/confluence/{conf_cloud_id}/wiki/rest/api/content/{page_id}",
                "title": title,
                "space_key": (page.get("space") or {}).get("key") or "",
            },
        )
        documents.append(doc); prepared += 1
        if first_title is None and title:
            first_title = title

        if len(documents) >= batch_size:
            info(f"Inserting batch of {len(documents)} into {vdb_id} ...")
            client.tool_runtime.rag_tool.insert(documents=documents, vector_db_id=vdb_id, chunk_size_in_tokens=512)
            inserted += len(documents); documents.clear()

    info(f"Prepared {prepared} page(s)")
    if documents:
        info(f"Inserting final batch of {len(documents)} into {vdb_id} ...")
        client.tool_runtime.rag_tool.insert(documents=documents, vector_db_id=vdb_id, chunk_size_in_tokens=512)
        inserted += len(documents)

    if inserted: info(f"Inserted {inserted} document(s) into {vdb_id}")
    else:        warn("No documents inserted (check filters/CQL).")

    info("Verifying vector store file status...")
    if not verify_vector_store(llama_base_url, vdb_id):
        error("Vector store verification failed (see above).")
        error("This is a demo project - please follow the README troubleshooting and try recreating the vector store.")
        return 4

    info("Done.")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        warn("Interrupted."); raise SystemExit(130)
