"""Funções utilitárias compartilhadas para busca e resposta do Sophia."""

from __future__ import annotations

import hashlib
import json
import logging
import os
from typing import Any, Dict, List, Optional, Sequence

import psycopg
from openai import OpenAI
from psycopg.rows import dict_row


logger = logging.getLogger("sophia.search")

client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
DB_URL = os.getenv("DATABASE_URL")
GEN_MODEL = os.getenv("GEN_MODEL", "gpt-5")
EXP_MODEL = os.getenv("EXPANSION_MODEL", GEN_MODEL)
REASONING_EFFORT = os.getenv("REASONING_EFFORT", "high")
TOPK = int(os.getenv("TOPK", "12"))
EXPANSIONS = int(os.getenv("EXPANSIONS", "4"))
RERANK_TOP = int(os.getenv("RERANK_TOP", "24"))
SELF_RAG = os.getenv("SELF_RAG", "true").lower() == "true"
USE_QA_CACHE = os.getenv("USE_QA_CACHE", "true").lower() == "true"
QA_CACHE_TTL_DAYS = int(os.getenv("QA_CACHE_TTL_DAYS", "90"))
FEEDBACK_ALPHA = float(os.getenv("FEEDBACK_ALPHA", "0.15"))
GLOSSARY_BOOST = float(os.getenv("GLOSSARY_BOOST", "0.2"))
NOTES_BOOST = float(os.getenv("NOTES_BOOST", "0.35"))
EMBED_DIM = int(os.getenv("EMBED_DIM", "1536"))


SQL_BASE = f"""
WITH q AS (
  SELECT websearch_to_tsquery('portuguese', %(q)s) AS tsq,
         %(qvec)s::vector({EMBED_DIM}) AS qvec
),
lex AS (
  SELECT id, ts_rank_cd(d.tsv, q.tsq) AS lscore
  FROM docs d, q
  WHERE d.tsv @@ q.tsq
  ORDER BY lscore DESC
  LIMIT 300
),
vec AS (
  SELECT id, 1 - (d.embedding <=> q.qvec) AS vscore
  FROM docs d, q
  WHERE d.embedding IS NOT NULL
  ORDER BY d.embedding <=> q.qvec
  LIMIT 300
),
u AS (
  SELECT COALESCE(lex.id, vec.id) AS id,
         COALESCE(lex.lscore, 0) AS lscore,
         COALESCE(vec.vscore, 0) AS vscore
  FROM lex
  FULL OUTER JOIN vec ON lex.id = vec.id
),
joined AS (
  SELECT d.id, d.path, d.chunk_no, d.title, d.meta, d.content,
         (0.6 * lscore + 0.4 * vscore) AS base_score
  FROM u JOIN docs d ON d.id = u.id
),
fb AS (
  SELECT doc_id, SUM(signal)::REAL AS fscore FROM feedback GROUP BY doc_id
)
SELECT j.*, COALESCE(fb.fscore, 0) AS fscore
FROM joined j
LEFT JOIN fb ON fb.doc_id = j.id
ORDER BY base_score DESC
LIMIT %(n)s;
"""


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest()


def embed_query(q: str, embed_model: str) -> Optional[List[float]]:
    """Retorna embedding para a consulta ou ``None`` em caso de falha."""

    try:
        return client.embeddings.create(model=embed_model, input=q).data[0].embedding
    except Exception as exc:  # pragma: no cover - fallback defensivo
        logger.exception("Falha ao gerar embedding para a consulta", exc_info=exc)
        return None


def expand_query(q: str) -> List[str]:
    """Expande a consulta com variações, mantendo sempre o texto original."""

    if EXPANSIONS <= 0:
        return [q]

    prompt = (
        f"Gere {EXPANSIONS} variações curtas e técnicas para a consulta abaixo, uma por linha.\n\n"
        f"Consulta: {q}"
    )

    try:
        r = client.chat.completions.create(
            model=EXP_MODEL,
            messages=[{"role": "user", "content": prompt}],
            temperature=0.3,
        )
        raw = r.choices[0].message.content or ""
    except Exception as exc:  # pragma: no cover - fallback defensivo
        logger.exception(
            "Falha ao expandir consulta; seguindo apenas com a consulta original", exc_info=exc
        )
        raw = ""

    lines = [l.strip("-• ").strip() for l in raw.splitlines() if l.strip()]
    uniq: List[str] = []
    seen: set[str] = set()
    for s in [q] + lines:
        if s not in seen:
            uniq.append(s)
            seen.add(s)
        if len(uniq) >= EXPANSIONS + 1:
            break
    return uniq


def rerank_pairs(question: str, items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Aplica reranqueamento via LLM às passagens recuperadas."""

    if not items:
        return items

    chunks = items[: int(os.getenv("RERANK_TOP", "24"))]
    trechos = "\n".join([f"[{i}] {c['content'][:800]}" for i, c in enumerate(chunks)])
    msgs = [
        {
            "role": "system",
            "content": "Dê nota 0..10 para relevância de cada trecho vs pergunta. Responda JSON: [{idx,score}]",
        },
        {
            "role": "user",
            "content": "Pergunta: " + question + "\n\nTrechos:\n" + trechos,
        },
    ]

    try:
        r = client.chat.completions.create(model=EXP_MODEL, messages=msgs, temperature=0)
        raw = r.choices[0].message.content or "[]"
    except Exception as exc:  # pragma: no cover - fallback defensivo
        logger.exception("Falha ao reordenar trechos; mantendo ordem original", exc_info=exc)
        raw = "[]"

    try:
        scores = json.loads(raw)
        for s in scores:
            idx = s.get("idx")
            sc = float(s.get("score", 0))
            if isinstance(idx, int) and 0 <= idx < len(chunks):
                chunks[idx]["rerank"] = sc
    except Exception:  # pragma: no cover - fallback defensivo
        for i, _ in enumerate(chunks):
            chunks[i]["rerank"] = 0.0

    for i in range(len(chunks), len(items)):
        items[i]["rerank"] = 0.0

    for it in items:
        it["final_score"] = (
            it.get("base_score", 0)
            + FEEDBACK_ALPHA * it.get("fscore", 0)
            + (it.get("rerank", 0) / 10.0)
        )

    items.sort(key=lambda x: x["final_score"], reverse=True)
    return items


def apply_glossary_boost(question: str, rows: List[Dict[str, Any]]):
    if GLOSSARY_BOOST <= 0:
        return rows

    try:
        with psycopg.connect(DB_URL) as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT term, weight FROM glossary")
            terms = cur.fetchall()
    except psycopg.Error as exc:  # pragma: no cover - fallback defensivo
        logger.warning("Não foi possível aplicar reforço do glossário: %s", exc)
        return rows

    ql = question.lower()
    for r in rows:
        bonus = 0.0
        txt = (r.get("content") or "").lower()
        for t in terms:
            term = t["term"].lower()
            w = float(t["weight"] or 1.0)
            if term in ql or term in txt:
                bonus += GLOSSARY_BOOST * w * 0.1
        r["base_score"] += bonus
    return rows


def inject_notes(rows: List[Dict[str, Any]]):
    if NOTES_BOOST <= 0:
        return rows

    try:
        with psycopg.connect(DB_URL) as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT id, text FROM notes ORDER BY created_at DESC LIMIT 50;")
            ns = cur.fetchall()
    except psycopg.Error as exc:  # pragma: no cover - fallback defensivo
        logger.warning("Não foi possível recuperar notas adicionais: %s", exc)
        return rows

    for n in ns:
        rows.append(
            {
                "id": 10_000_000 + n["id"],
                "path": f"NOTE:{n['id']}",
                "chunk_no": 0,
                "title": "Nota",
                "meta": {},
                "content": n["text"],
                "base_score": NOTES_BOOST,
                "fscore": 0.0,
            }
        )
    return rows


def try_cache(question: str):
    if not USE_QA_CACHE:
        return None

    try:
        with psycopg.connect(DB_URL) as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """SELECT answer, citations, created_at FROM qa_cache
                       WHERE qhash=%s AND created_at >= now() - interval '%s days'""",
                (sha(question), os.getenv("QA_CACHE_TTL_DAYS", "90")),
            )
            return cur.fetchone()
    except psycopg.Error as exc:  # pragma: no cover - fallback defensivo
        logger.warning("Não foi possível consultar cache de QA: %s", exc)
        return None


def save_cache(question: str, answer: str, citations: List[Dict[str, Any]]):
    if not USE_QA_CACHE:
        return

    try:
        with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
            cur.execute(
                """INSERT INTO qa_cache(qhash,question,answer,citations,created_at)
                       VALUES(%s,%s,%s,%s,now())
                       ON CONFLICT (qhash) DO UPDATE SET
                         question=EXCLUDED.question, answer=EXCLUDED.answer,
                         citations=EXCLUDED.citations, created_at=now()""",
                (sha(question), question, answer, psycopg.types.json.Json(citations)),
            )
            conn.commit()
    except psycopg.Error as exc:  # pragma: no cover - fallback defensivo
        logger.warning("Não foi possível salvar resposta em cache: %s", exc)


def self_rag_verify(draft: str, contexts: str) -> str:
    if os.getenv("SELF_RAG", "true").lower() != "true":
        return draft

    prompt = (
        "Revise a resposta abaixo, mantendo apenas afirmações suportadas pelo CONTEXTO.\n"
        "Se algo não estiver claramente suportado, remova ou marque como incerto. Mantenha as citações [#n].\n"
        f"RESPOSTA:\n{draft}\n\nCONTEXTO:\n{contexts}"
    )

    try:
        r = client.chat.completions.create(
            model=GEN_MODEL,
            messages=[
                {"role": "system", "content": "Você é um verificador factual rigoroso."},
                {"role": "user", "content": prompt},
            ],
            temperature=0.0,
        )
        return r.choices[0].message.content or draft
    except Exception as exc:  # pragma: no cover - fallback defensivo
        logger.warning("Falha ao realizar auto-verificação RAG: %s", exc)
        return draft


def retrieve_hybrid(
    question: str, qvec: Optional[Sequence[float]], k: int = TOPK
) -> List[Dict[str, Any]]:
    if qvec is None:
        return []

    try:
        with psycopg.connect(DB_URL) as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SET hnsw.ef_search=100;")
            cur.execute(
                SQL_BASE,
                {
                    "q": question,
                    "qvec": qvec,
                    "n": max(k * 3, int(os.getenv("RERANK_TOP", "24"))),
                },
            )
            return cur.fetchall()
    except psycopg.Error as exc:  # pragma: no cover - fallback defensivo
        logger.exception("Erro ao executar busca híbrida", exc_info=exc)
        return []

