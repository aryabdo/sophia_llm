from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import Optional
import os
import json
import subprocess
import sys
import psycopg

from search_answer import answer as answer_single
from search_chat import chat_respond

DB_URL = os.getenv("DATABASE_URL")
APP_DIR = os.path.dirname(__file__)
app = FastAPI(title="Sophia RAG API", version="1.1")

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
