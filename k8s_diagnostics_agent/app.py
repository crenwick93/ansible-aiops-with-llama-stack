import os
import json
import html
import re
import uuid
import logging
from functools import lru_cache
from typing import Any, Optional

from fastapi import FastAPI, HTTPException, Request
from llama_stack_client import LlamaStackClient, Agent


LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("k8s-diagnostics-agent")

# Reduce noisy libraries (httpx/httpcore) and suppress /healthz access logs
for noisy in ("httpx", "httpcore"):
    try:
        logging.getLogger(noisy).setLevel(logging.WARNING)
    except Exception:
        pass

class SuppressHealthzFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        if "GET /healthz" in msg or " /healthz " in msg:
            return False
        return True

logging.getLogger("uvicorn.access").addFilter(SuppressHealthzFilter())


def _get_env_optional(name: str, default: Optional[str] = None) -> Optional[str]:
    value = os.getenv(name, default)
    if value is None:
        return None
    return value.strip() or default


def _render_inline_code_escaped(text: str) -> str:
    """Escape HTML and convert inline `code` spans to <code>...</code>."""
    if not isinstance(text, str):
        text = str(text)
    parts: list[str] = []
    last = 0
    for m in re.finditer(r"`([^`]+)`", text):
        normal = text[last:m.start()]
        parts.append(html.escape(normal))
        parts.append(f"<code>{html.escape(m.group(1))}</code>")
        last = m.end()
    parts.append(html.escape(text[last:]))
    return "".join(parts)


def render_simple_markdown_to_html(text: str) -> str:
    """
    Minimal markdown-to-HTML for ServiceNow work notes:
    - Convert * / - bullet lists to <ul><li>
    - Convert ``` fenced blocks to <pre><code>
    - Convert inline `code` spans
    - Escape all other content
    """
    if not text:
        return ""
    lines = text.splitlines()
    html_parts: list[str] = []
    in_list = False
    in_code = False
    for raw in lines:
        line = raw.rstrip("\r")
        if line.strip().startswith("```"):
            if in_code:
                html_parts.append("</code></pre>")
                in_code = False
            else:
                if in_list:
                    html_parts.append("</ul>")
                    in_list = False
                html_parts.append("<pre><code>")
                in_code = True
            continue
        if in_code:
            html_parts.append(html.escape(line))
            continue
        stripped = line.strip()
        if stripped.startswith("* ") or stripped.startswith("- "):
            if not in_list:
                html_parts.append("<ul>")
                in_list = True
            content = stripped[2:]
            html_parts.append(f"<li>{_render_inline_code_escaped(content)}</li>")
            continue
        else:
            if in_list:
                html_parts.append("</ul>")
                in_list = False
        if stripped == "":
            html_parts.append("<br/>")
        else:
            html_parts.append(f"<p>{_render_inline_code_escaped(line)}</p>")
    if in_list:
        html_parts.append("</ul>")
    if in_code:
        html_parts.append("</code></pre>")
    return "\n".join(html_parts)


@lru_cache(maxsize=1)
def get_client() -> LlamaStackClient:
    base_url = (_get_env_optional("LLAMA_BASE_URL") or
                "http://lsd-llama-milvus-inline-service.default.svc.cluster.local:8321").rstrip("/")
    logger.info("Using Llama Stack at %s", base_url)
    return LlamaStackClient(base_url=base_url)


def select_model(client: LlamaStackClient) -> str:
    preferred_id = _get_env_optional("MODEL_ID") or _get_env_optional("PREFERRED_MODEL_ID")
    models = list(client.models.list())
    if preferred_id:
        selected = next((m for m in models if (getattr(m, "identifier", None) or getattr(m, "model_id", None)) == preferred_id), None)
        if selected:
            return getattr(selected, "identifier", None) or getattr(selected, "model_id", None)
        logger.warning("Preferred model %s not found; falling back to auto-select", preferred_id)
    preferred = next((m for m in models if getattr(m, "model_type", None) == "llm" and getattr(m, "provider_id", None) == "vllm-inference"), None)
    if preferred:
        return getattr(preferred, "identifier", None) or getattr(preferred, "model_id", None)
    generic = next((m for m in models if getattr(m, "model_type", None) == "llm"), None)
    if not generic:
        raise RuntimeError("No LLM models available on Llama Stack")
    return getattr(generic, "identifier", None) or getattr(generic, "model_id", None)


@lru_cache(maxsize=1)
def get_vector_store_ids() -> list[str]:
    raw = _get_env_optional("VECTOR_STORE_IDS", "") or ""
    if raw:
        ids = [s.strip() for s in raw.split(",") if s.strip()]
        if ids:
            logger.info("Using VECTOR_STORE_IDS=%s", ids)
            return ids
    single = _get_env_optional("VECTOR_DB_ID", "") or ""
    if single:
        logger.info("Using VECTOR_DB_ID=%s", single)
        return [single]
    return []


@lru_cache(maxsize=1)
def get_rag_agent() -> tuple[LlamaStackClient, Agent, str, list[str]]:
    """
    RAG-only agent (no live MCP). Used in /diagnose phase 2 to correlate MCP findings with KB.
    Keep base instructions minimal; the correlation prompt is provided per-call.
    """
    client = get_client()
    model_id = select_model(client)
    vector_store_ids = get_vector_store_ids()
    rag_instructions = ""  # keep empty; main RAG guidance is passed per-turn via build_rag_correlation_instructions()
    tools: list[dict] = []
    if vector_store_ids:
        tools.append({"type": "file_search", "vector_store_ids": vector_store_ids})
    agent = Agent(client, model=model_id, instructions=rag_instructions, tools=tools)
    return client, agent, model_id, vector_store_ids


def get_mcp_server() -> tuple[str, str]:
    """
    Resolve the MCP server URL/label.
    Priority:
      1) Explicit env: MCP_SERVER_URL or REMOTE_OCP_MCP_URL
      2) Discover from Llama Stack toolgroups (default 'mcp::kubernetes')
    """
    server_url = _get_env_optional("MCP_SERVER_URL") or _get_env_optional("REMOTE_OCP_MCP_URL")
    if not server_url:
        try:
            client = get_client()
            toolgroup_id = _get_env_optional("MCP_TOOLGROUP_ID", "mcp::kubernetes") or "mcp::kubernetes"
            groups = list(getattr(client, "toolgroups").list())
            tg = next((g for g in groups if getattr(g, "identifier", None) == toolgroup_id), None)
            mcp = getattr(tg, "mcp_endpoint", None) if tg else None
            # Endpoint may be an object or dict; support both
            uri = getattr(mcp, "uri", None) if mcp is not None else None
            if not uri and isinstance(mcp, dict):
                uri = mcp.get("uri")
            if uri:
                server_url = str(uri)
        except Exception:
            # Fall through to error if still not resolved
            server_url = None
    if not server_url:
        raise RuntimeError("MCP server URL not configured. Set MCP_SERVER_URL/REMOTE_OCP_MCP_URL or ensure toolgroup discovery works.")
    server_label = _get_env_optional("MCP_SERVER_LABEL", "kubernetes-mcp") or "kubernetes-mcp"
    return server_url.rstrip("/"), server_label


def extract_output_text(result: Any) -> str:
    try:
        if hasattr(result, "output") and result.output:
            for item in reversed(result.output):
                item_type = getattr(item, "type", None)
                content_list = getattr(item, "content", None)
                if item_type == "message" and content_list:
                    for c in content_list:
                        text = getattr(c, "text", None)
                        if text:
                            return text
        if hasattr(result, "output_text"):
            output_text = getattr(result, "output_text")
            if isinstance(output_text, str) and output_text:
                return output_text
    except Exception:
        pass
    if isinstance(result, dict):
        output = result.get("output")
        if isinstance(output, list):
            for item in reversed(output):
                if item.get("type") == "message":
                    for c in item.get("content", []):
                        text = c.get("text")
                        if text:
                            return text
    return str(result)


def build_mcp_instructions() -> str:
    prompt = _get_env_optional("K8S_MCP_AGENT_PROMPT") or _get_env_optional("MCP_PROMPT")
    if not prompt:
        raise RuntimeError("K8S_MCP_AGENT_PROMPT (or MCP_PROMPT) is not set. Edit ConfigMap k8-diagnostics-agent-prompts (key: k8s_mcp_agent_prompt) and redeploy.")
    return prompt

def _get_text_from_turn_like_notebook(turn: Any) -> str:
    """
    Extract assistant text similar to the notebook's helper:
    - Prefer output_text
    - Else parse turn.to_dict().output[].content[].text for types output_text/text
    - Else fall back to extract_output_text
    """
    try:
        t = getattr(turn, "output_text", None)
        if isinstance(t, str) and t.strip():
            return t
        if hasattr(turn, "to_dict"):
            d = turn.to_dict()
        elif isinstance(turn, dict):
            d = turn
        else:
            d = None
        if isinstance(d, dict):
            pieces: list[str] = []
            for item in (d.get("output") or []):
                for c in (item.get("content") or []):
                    if isinstance(c, dict) and c.get("type") in ("output_text", "text"):
                        txt = c.get("text", "")
                        if isinstance(txt, str) and txt:
                            pieces.append(txt)
            if pieces:
                return "\n".join(pieces)
            txt2 = d.get("text")
            if isinstance(txt2, str) and txt2.strip():
                return txt2
    except Exception:
        pass
    return extract_output_text(turn)

# Override: require RAG_CORRELATION_AGENT_PROMPT from ConfigMap/env
def build_rag_correlation_instructions() -> str:  # noqa: E0102
    prompt = _get_env_optional("RAG_CORRELATION_AGENT_PROMPT") or _get_env_optional("RAG_PROMPT")
    if not prompt:
        raise RuntimeError("RAG_CORRELATION_AGENT_PROMPT (or RAG_PROMPT) is not set. Edit ConfigMap k8-diagnostics-agent-prompts (key: rag_correlation_agent_prompt) and redeploy.")
    return prompt


def summarize_incident_payload(payload: Any) -> str:
    try:
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":"), default=str)[:4000]
    except Exception:
        return str(payload)[:4000]


app = FastAPI(title="K8s Diagnostics Agent (MCP + RAG)", version="0.1.0")


@app.get("/healthz")
def healthz() -> dict:
    try:
        # Use cached agent to avoid repeated model listing
        _, _, model_id, vector_store_ids = get_rag_agent()
        mcp_url, _ = get_mcp_server()
        return {"status": "ok", "model": model_id, "vector_store_ids": vector_store_ids, "mcp_server_url": mcp_url}
    except Exception as exc:
        logger.exception("Health check failed: %s", exc)
        raise HTTPException(status_code=500, detail=str(exc))


def _run_pipeline(payload: Any) -> dict:
    request_id = uuid.uuid4().hex[:8]
    logger.info("PIPELINE start rid=%s", request_id)

    try:
        # Derive an incident question string for prompts (as in the notebook)
        incident_question = ""
        if isinstance(payload, str):
            maybe_q = payload
            if maybe_q.strip():
                incident_question = maybe_q.strip()
        elif isinstance(payload, dict):
            maybe_q = (
                payload.get("incident_question")
                or payload.get("question")
                or payload.get("incident")
                or payload.get("description")
                or payload.get("short_description")
                or ""
            )
            if isinstance(maybe_q, str) and maybe_q.strip():
                incident_question = maybe_q.strip()
        if not incident_question:
            incident_question = "Please investigate the following incident.\n" + summarize_incident_payload(payload)

        client = get_client()
        model_id = select_model(client)
        mcp_url, mcp_label = get_mcp_server()
        mcp_messages = [
            {"role": "system", "content": build_mcp_instructions()},
            {"role": "user", "content": incident_question},
        ]
        mcp_result = client.responses.create(
            model=model_id,
            input=mcp_messages,
            tools=[{"type": "mcp", "server_url": mcp_url, "server_label": mcp_label, "require_approval": "never"}],
            temperature=0.0,
            max_infer_iters=8,
        )
        mcp_findings = extract_output_text(mcp_result).strip()
        # Remove any stray pseudo-tool call lines like [resources_get(...)]
        try:
            import re as _re_mcp
            lines = mcp_findings.splitlines()
            cleaned = []
            for ln in lines:
                if _re_mcp.match(r"^\s*\[[A-Za-z_]+\(", ln) and ln.strip().endswith(")"):
                    # skip pseudo tool-call echo
                    continue
                cleaned.append(ln)
            mcp_findings = "\n".join(cleaned).strip()
        except Exception:
            pass
    except Exception as exc:
        logger.exception("MCP diagnostics failed rid=%s: %s", request_id, exc)
        raise HTTPException(status_code=500, detail=f"MCP diagnostics failed: {exc}")

    try:
        _, rag_agent, _, _ = get_rag_agent()
        session = rag_agent.create_session(session_name=f"k8s-diag-{uuid.uuid4().hex[:6]}")
        session_id = (
            getattr(session, "id", None)
            or getattr(session, "session_id", None)
            or getattr(session, "identifier", None)
            or str(session)
        )
        rag_messages = [
            {"role": "system", "content": build_rag_correlation_instructions()},
            {
                "role": "user",
                "content": (
                    "Incident description:\n"
                    + incident_question
                    + "\n\nCluster findings from MCP diagnostics:\n"
                    + (mcp_findings or "(none)")
                ),
            },
        ]
        rag_result = rag_agent.create_turn(messages=rag_messages, session_id=session_id, stream=False)
        # Dual-output extraction (Cell 8 logic)
        raw_text = _get_text_from_turn_like_notebook(rag_result).strip()
        rag_explanation = raw_text
        rag_json = None
        try:
            import re as _re
            # Be resilient to code fences/backticks and HTML line breaks in the model output
            raw_for_json = raw_text
            try:
                raw_for_json = _re.sub(r"`{3,}[\w-]*", "", raw_for_json)  # remove ``` or ```json fences
                raw_for_json = raw_for_json.replace("<br/>", "\n").replace("<br>", "\n")
            except Exception:
                pass
            # Find the innermost JSON object between the markers, ignoring any leading/trailing noise
            m = _re.search(r"### JSON_START[\s\S]*?(\{[\s\S]*\})[\s\S]*?### JSON_END", raw_for_json, flags=_re.DOTALL)
            if m:
                json_str = m.group(1).strip()
                try:
                    m2 = _re.search(r"### JSON_START", raw_text)
                    if m2:
                        rag_explanation = raw_text[: m2.start()].strip()
                except Exception:
                    pass
                try:
                    rag_json = json.loads(json_str)
                except Exception:
                    rag_json = None
            # Fallback 1: ```json fenced block
            if rag_json is None:
                m_json = _re.search(r"```json\s*(\{[\s\S]*?\})\s*```", raw_for_json, flags=_re.DOTALL)
                if m_json:
                    try:
                        rag_json = json.loads(m_json.group(1).strip())
                    except Exception:
                        rag_json = None
            # Fallback 2: generic JSON object extraction around a known key
            if rag_json is None:
                # Try to find the block containing proposed_remediation_via_aap
                key_idx = raw_for_json.find("proposed_remediation_via_aap")
                start_idx = 0
                end_idx = len(raw_for_json)
                if key_idx != -1:
                    # scan backward to nearest '{'
                    i = key_idx
                    while i >= 0 and raw_for_json[i] != '{':
                        i -= 1
                    start_idx = max(i, 0)
                    # scan forward with brace balance
                    brace = 0
                    j = start_idx
                    while j < len(raw_for_json):
                        ch = raw_for_json[j]
                        if ch == '{':
                            brace += 1
                        elif ch == '}':
                            brace -= 1
                            if brace == 0:
                                end_idx = j + 1
                                break
                        j += 1
                candidate = raw_for_json[start_idx:end_idx].strip()
                # As a last resort, try to load the candidate
                if candidate.startswith('{') and candidate.endswith('}'):
                    try:
                        rag_json = json.loads(candidate)
                    except Exception:
                        pass
        except Exception:
            pass
    except Exception as exc:
        logger.exception("RAG correlation failed rid=%s: %s", request_id, exc)
        raise HTTPException(status_code=500, detail=f"RAG correlation failed: {exc}")

    # Build HTML worknotes and wrap in ServiceNow [code]...[/code]
    # Phase 1 (MCP): format bullets/code fences
    mf_html = render_simple_markdown_to_html(mcp_findings or "(no MCP cluster findings text returned)")

    # Build Phase 2 (RAG) from structured JSON when available to avoid markdown artifacts
    rag_section_html = ""
    if isinstance(rag_json, dict) and rag_json:
        probable = rag_json.get("probable_cause") or ""
        evidence = rag_json.get("evidence_mapping") or []
        next_steps = rag_json.get("next_steps") or []
        proposed = rag_json.get("proposed_remediation_via_aap") or {}
        kb = rag_json.get("key_kb_evidence") or []
        ref_doc = rag_json.get("reference_document") or ""

        # Probable cause
        rag_parts = ["<h4>1) Probable cause</h4>", f"<p>{html.escape(probable)}</p>" if probable else ""]

        # Evidence mapping
        if isinstance(evidence, list) and evidence:
            rag_parts.append("<h4>2) Evidence mapping</h4>")
            rag_parts.append("<ul>")
            for item in evidence:
                rag_parts.append(f"<li>{html.escape(str(item))}</li>")
            rag_parts.append("</ul>")

        # Next steps (show commands consolidated as a single code block)
        if isinstance(next_steps, list) and next_steps:
            rag_parts.append("<h4>3) Next steps</h4>")
            commands = []
            for step in next_steps:
                cmd = (step or {}).get("command")
                if isinstance(cmd, str) and cmd.strip():
                    commands.append(cmd.strip())
            if commands:
                cmd_block = html.escape("\n".join(commands))
                rag_parts.append(f"<pre><code>{cmd_block}</code></pre>")

        # Proposed remediation JSON
        if isinstance(proposed, dict) and proposed:
            try:
                proposed_json_str = json.dumps(proposed, indent=2)
            except Exception:
                proposed_json_str = str(proposed)
            rag_parts.append("<h4>4) Proposed remediation via AAP</h4>")
            rag_parts.append(f"<pre><code>{html.escape(proposed_json_str)}</code></pre>")

        # Key KB evidence
        if isinstance(kb, list) and kb:
            rag_parts.append("<h4>5) Key KB evidence</h4>")
            rag_parts.append("<ul>")
            for item in kb:
                # Avoid mentioning internal fallback explicitly if present
                text = str(item).replace("canonical fallback", "project documentation")
                rag_parts.append(f"<li>{html.escape(text)}</li>")
            rag_parts.append("</ul>")

        # Reference document
        if isinstance(ref_doc, str) and ref_doc.strip():
            rag_parts.append("<h4>6) Reference document</h4>")
            rag_parts.append(f"<p><em>{html.escape(ref_doc.strip())}</em></p>")

        rag_section_html = "\n".join([p for p in rag_parts if p])
    else:
        # Fallback: format bullets/code fences
        rag_section_html = render_simple_markdown_to_html(rag_explanation or "(no formatted RAG text returned)")

    worknotes_html = (
        "<h2>MCP-First Diagnostics + RAG Correlation (Special Payment Project)</h2>\n"
        "<hr />\n"
        "<h3>Phase 1 – MCP diagnostics (live cluster)</h3>\n"
        f"{mf_html}\n"
        "<h3>Phase 2 – RAG correlation (knowledge base)</h3>\n"
        f"{rag_section_html}\n"
        "<hr />\n<p><strong>End of diagnostics</strong></p>\n"
    )
    worknotes_wrapped = "[code]" + worknotes_html + "[/code]"

    logger.info("PIPELINE done rid=%s mcp_chars=%s rag_chars=%s", request_id, len(mcp_findings), len(rag_explanation))
    return {
        "session_id": session_id,
        "incident": payload,
        "mcp_findings": mcp_findings,
        "knowledge_base_rag_cross_reference": rag_explanation,
        "worknotes": worknotes_wrapped,
        "output_as_json": rag_json,
    }


@app.post("/diagnose")
async def diagnose(request: Request) -> dict:
    payload: Any = None
    # Try JSON first; fall back to raw text (ServiceNow description sent as text/plain)
    try:
        payload = await request.json()
    except Exception:
        try:
            raw = await request.body()
            if raw:
                decoded = raw.decode("utf-8", errors="ignore").strip()
                if decoded:
                    payload = decoded
        except Exception:
            pass
    if payload is None:
        raise HTTPException(status_code=400, detail="Request body must be JSON or plain text")
    client = get_client()
    model_id = select_model(client)
    results = _run_pipeline(payload)
    return {"model": model_id, **results}


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", os.getenv("SERVICE_PORT", "8080")))
    uvicorn.run("app:app", host="0.0.0.0", port=port, reload=False)


