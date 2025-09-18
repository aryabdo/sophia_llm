from fastapi import FastAPI, HTTPException, Header
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from typing import Optional
import os
import json
import subprocess
import sys
import psycopg
from pathlib import Path

from search_answer import answer as answer_single
from search_chat import chat_respond

DB_URL = os.getenv("DATABASE_URL")
APP_DIR = os.path.dirname(__file__)
app = FastAPI(title="Sophia RAG API", version="1.1")
ALLOW_FINETUNE = os.getenv("ALLOW_FINETUNE", "false").lower() == "true"
FINETUNE_TOKEN = os.getenv("FINETUNE_TOKEN") or os.getenv("ADMIN_TOKEN")
FINETUNE_HISTORY_FILE = Path(
    os.getenv(
        "FINETUNE_HISTORY",
        os.path.join(os.getenv("FINETUNE_DIR", "finetune"), "history.jsonl"),
    )
)
PUBLIC_URL = (os.getenv("PUBLIC_URL") or os.getenv("API_URL") or "http://localhost:18888").rstrip("/")
GPT_PLUGIN_NAME = os.getenv("GPT_PLUGIN_NAME", "Sophia RAG")
GPT_PLUGIN_DESCRIPTION = os.getenv(
    "GPT_PLUGIN_DESCRIPTION",
    "Ferramenta de busca híbrida do Sophia para consultas regulatórias e jurídicas.",
)
GPT_CONTACT_EMAIL = os.getenv("GPT_CONTACT_EMAIL", "contato@example.com")
GPT_LEGAL_URL = os.getenv("GPT_LEGAL_URL")
GPT_LOGO_URL = os.getenv("GPT_LOGO_URL", f"{PUBLIC_URL}/static/logo.png")

class AskIn(BaseModel):
    question: str
    top_k: Optional[int] = None

class ChatIn(BaseModel):
    session: str
    message: str

class AnalyzeIn(BaseModel):
    path: Optional[str] = None
    doc_id: Optional[int] = None
    k: Optional[int] = 40

class AnalyzeBatchIn(BaseModel):
    prefix: Optional[str] = None
    limit: Optional[int] = 50

class FeedbackIn(BaseModel):
    query_hash: str
    doc_id: int = Field(gt=0)
    signal: int = Field(ge=-1, le=1)


class FinetuneIn(BaseModel):
    status: Optional[str] = None
    watch: bool = False


def _append_finetune_history(entry: dict) -> None:
    if not entry:
        return
    if FINETUNE_HISTORY_FILE.exists():
        try:
            with FINETUNE_HISTORY_FILE.open("r", encoding="utf-8") as handle:
                for line in handle:
                    try:
                        if json.loads(line).get("job_id") == entry.get("job_id"):
                            return
                    except json.JSONDecodeError:
                        continue
        except OSError:
            pass
    FINETUNE_HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    with FINETUNE_HISTORY_FILE.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")

@app.get("/health")
def health():
    try:
        with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
            cur.execute("select 1")
            cur.fetchone()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"DB error: {e}")
    return {"ok": True}

@app.post("/ask")
def ask(inp: AskIn):
    ans, cites, qhash = answer_single(
        inp.question,
        k=inp.top_k or int(os.getenv("TOPK", "12")),
        return_metadata=True,
    )
    return {"answer": ans, "citations": cites, "query_hash": qhash}

@app.post("/chat")
def chat(inp: ChatIn):
    ans, cites, qhash = chat_respond(inp.session, inp.message)
    return {"answer": ans, "citations": cites, "query_hash": qhash}

@app.post("/analyze_doc")
def analyze_doc(inp: AnalyzeIn):
    cmd = [sys.executable, "-u", os.path.join(APP_DIR, "analyze_doc.py")]
    if inp.path:
        cmd += ["--path", inp.path]
    if inp.doc_id is not None:
        cmd += ["--doc_id", str(inp.doc_id)]
    if inp.k:
        cmd += ["--k", str(inp.k)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise HTTPException(status_code=500, detail=r.stderr.strip())
    try:
        return json.loads(r.stdout.strip())
    except Exception:
        return {"ok": True, "raw": r.stdout.strip()}

@app.post("/analyze_batch")
def analyze_batch(inp: AnalyzeBatchIn):
    cmd = [sys.executable, "-u", os.path.join(APP_DIR, "analyze_batch.py")]
    if inp.prefix:
        cmd += ["--prefix", inp.prefix]
    if inp.limit:
        cmd += ["--limit", str(inp.limit)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise HTTPException(status_code=500, detail=r.stderr.strip())
    try:
        return json.loads(r.stdout.strip())
    except Exception:
        return {"ok": True, "raw": r.stdout.strip()}

@app.post("/feedback")
def feedback(inp: FeedbackIn):
    try:
        with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO feedback(query_hash, doc_id, signal) VALUES (%s,%s,%s)",
                (inp.query_hash, inp.doc_id, inp.signal),
            )
            conn.commit()
    except psycopg.Error as exc:
        raise HTTPException(status_code=500, detail=f"DB error: {exc.pgerror or exc}") from exc
    return {"ok": True}


@app.post("/finetune")
def finetune(
    inp: FinetuneIn,
    x_admin_token: Optional[str] = Header(default=None, alias="x-admin-token"),
):
    if not ALLOW_FINETUNE:
        raise HTTPException(status_code=403, detail="fine-tuning desabilitado")
    expected_token = FINETUNE_TOKEN
    if expected_token:
        provided = x_admin_token or ""
        if provided.startswith("Bearer "):
            provided = provided.split(" ", 1)[1]
        if provided != expected_token:
            raise HTTPException(status_code=401, detail="token inválido")
    cmd = [sys.executable, "-u", os.path.join(APP_DIR, "finetune.py")]
    if inp.status:
        cmd += ["--status", inp.status]
    if inp.watch:
        cmd.append("--watch")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        detail = r.stderr.strip() or r.stdout.strip() or "erro ao executar finetune"
        raise HTTPException(status_code=500, detail=detail)
    try:
        payload = json.loads(r.stdout.strip() or "{}")
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=500, detail=f"resposta inválida: {exc}") from exc
    if not inp.status:
        _append_finetune_history(payload.get("history_entry"))
    return payload


@app.get("/.well-known/ai-plugin.json", include_in_schema=False)
def gpt_manifest():
    manifest = {
        "schema_version": "v1",
        "name_for_human": GPT_PLUGIN_NAME,
        "name_for_model": "sophia_rag",
        "description_for_human": GPT_PLUGIN_DESCRIPTION,
        "description_for_model": "Utilize esta ferramenta para responder perguntas com base em documentos indexados pela Sophia.",
        "auth": {"type": "none"},
        "api": {
            "type": "openapi",
            "url": f"{PUBLIC_URL}/openapi.json",
            "is_user_authenticated": False,
        },
        "contact_email": GPT_CONTACT_EMAIL,
        "legal_info_url": GPT_LEGAL_URL,
    }
    if GPT_LOGO_URL:
        manifest["logo_url"] = GPT_LOGO_URL
    return JSONResponse({k: v for k, v in manifest.items() if v is not None})


@app.get("/analysis")
def analysis(path: Optional[str] = None, limit: int = 50):
    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        if path:
            cur.execute("SELECT * FROM doc_analysis WHERE path=%s", (path,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="not found")
            cols = [d[0] for d in cur.description]
            return dict(zip(cols, row))
        cur.execute(
            "SELECT path, summary, created_at FROM doc_analysis ORDER BY created_at DESC LIMIT %s",
            (limit,),
        )
        return [
            {"path": p, "summary": s, "created_at": c.isoformat()}
            for p, s, c in cur.fetchall()
        ]

@app.get("/report")
def report(prefix: Optional[str] = None, limit: int = 100):
    cmd = [sys.executable, "-u", os.path.join(APP_DIR, "report_builder.py")]
    if prefix:
        cmd += ["--prefix", prefix]
    if limit:
        cmd += ["--limit", str(limit)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise HTTPException(status_code=500, detail=r.stderr.strip())
    return {"markdown": r.stdout}
