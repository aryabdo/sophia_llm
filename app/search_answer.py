from pathlib import Path
import os
from dotenv import load_dotenv
from openai import OpenAI
from search_utils import (
    embed_query,
    expand_query,
    retrieve_hybrid,
    rerank_pairs,
    apply_glossary_boost,
    inject_notes,
    try_cache,
    save_cache,
    self_rag_verify,
    sha,
)

load_dotenv(Path(__file__).with_name(".env"), override=True)
GEN_MODEL = os.getenv("GEN_MODEL", "gpt-5")
REASONING_EFFORT = os.getenv("REASONING_EFFORT", "high")
EMBED_MODEL = os.getenv("EMBED_MODEL", "text-embedding-3-small")
TOPK = int(os.getenv("TOPK", "12"))
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

PROMPT = """
Você é um analista jurídico-regulatório. Responda usando apenas o contexto abaixo.
- Faça um resumo crítico.
- Liste favoráveis e contrários com justificativas.
- Compare documentos quando houver divergências/convergências.
- Cite fontes como [#n] + caminho.
- Se faltar base, diga o que falta.

Pergunta: "{question}"

Contexto:
{contexts}
"""

def answer(question, k=TOPK, max_ctx_chars=20000, return_metadata=False):
    qhash = sha(question)
    row = try_cache(question)
    if row:
        answer_text = row["answer"]
        citations = row.get("citations") or []
        if return_metadata:
            return answer_text, citations, qhash
        print(answer_text)
        return

    variants = expand_query(question)
    all_rows = []
    for v in variants:
        qvec = embed_query(v, os.getenv("EMBED_MODEL", "text-embedding-3-small"))
        rows = retrieve_hybrid(v, qvec, k=k)
        all_rows.extend(rows)
    by_id = {r["id"]: r for r in all_rows}
    rows = list(by_id.values())
    rows = apply_glossary_boost(question, rows)
    rows = inject_notes(rows)
    rows = rerank_pairs(question, rows)

    blocks = []
    total = 0
    cites = []
    for i, r in enumerate(rows[:k], 1):
        header = f"[#{i}] {r['path']} (chunk {r['chunk_no']})"
        body = (r["content"] or "").replace("\n", " ").strip()
        piece = f"{header}\n{body}\n"
        if total + len(piece) > max_ctx_chars:
            break
        blocks.append(piece)
        total += len(piece)
        cites.append(
            {
                "n": i,
                "id": r["id"],
                "path": r["path"],
                "chunk": r["chunk_no"],
            }
        )
    contexts = "\n---\n".join(blocks)
    user_prompt = PROMPT.format(question=question, contexts=contexts)
    resp = client.chat.completions.create(
        model=GEN_MODEL,
        messages=[
            {
                "role": "system",
                "content": "Responda tecnicamente, sem inventar fatos, e cite fontes.",
            },
            {"role": "user", "content": user_prompt},
        ],
        temperature=0.2,
        reasoning={"effort": REASONING_EFFORT},
    )
    draft = resp.choices[0].message.content
    final = self_rag_verify(draft, contexts)
    save_cache(question, final, cites)

    if return_metadata:
        return final, cites, qhash

    print(final)

if __name__ == "__main__":
    import sys

    q = " ".join(sys.argv[1:]) or "Quais entendimentos favoráveis e contrários sobre [tema]?"
    answer(q)
