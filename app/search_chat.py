from pathlib import Path
import os
import json
from dotenv import load_dotenv
from openai import OpenAI
from search_utils import (
    retrieve_hybrid,
    apply_glossary_boost,
    inject_notes,
    rerank_pairs,
    self_rag_verify,
    sha,
)

load_dotenv(Path(__file__).with_name(".env"), override=True)
GEN_MODEL = os.getenv("GEN_MODEL", "gpt-5")
REASONING_EFFORT = os.getenv("REASONING_EFFORT", "high")
EMBED_MODEL = os.getenv("EMBED_MODEL", "text-embedding-3-small")
TOPK = int(os.getenv("TOPK", "12"))
SESS_DIR = Path("/opt/rag-sophia/sessions")
SESS_DIR.mkdir(parents=True, exist_ok=True)
SYSTEM = "Você é um assistente analítico. Baseie-se no contexto recuperado e no histórico. Cite fontes como [#n] + caminho."
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

def chat_respond(session_name: str, user_text: str):
    qhash = sha(user_text)
    qvec = client.embeddings.create(model=EMBED_MODEL, input=user_text).data[0].embedding
    rows = retrieve_hybrid(user_text, qvec, k=TOPK)
    seen = set()
    uniq = []
    for r in rows:
        if r["id"] in seen:
            continue
        seen.add(r["id"])
        uniq.append(r)
    rows = apply_glossary_boost(user_text, uniq)
    rows = inject_notes(rows)
    rows = rerank_pairs(user_text, rows)
    blocks = []
    cites = []
    total = 0
    max_ctx = 18000
    for i, r in enumerate(rows[:TOPK], 1):
        header = f"[#{i}] {r['path']} (chunk {r['chunk_no']})"
        body = (r["content"] or "").replace("\n", " ").strip()
        piece = f"{header}\n{body}\n"
        if total + len(piece) > max_ctx:
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
    prompt = (
        f"Pergunta: \"{user_text}\"\n\nContexto recuperado:\n{contexts}\n\n"
        "Regras:\n- Seja específico e crítico.\n- Liste prós/contras quando fizer sentido.\n"
        "- Cite fontes como [#n] + caminho.\n- Se faltar base, diga o que falta."
    )
    resp = client.chat.completions.create(
        model=GEN_MODEL,
        messages=[{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}],
        temperature=0.2,
        reasoning={"effort": REASONING_EFFORT},
    )
    draft = resp.choices[0].message.content or "(sem conteúdo)"
    final = self_rag_verify(draft, contexts)
    return final, cites, qhash

if __name__ == "__main__":
    import sys

    sess = sys.argv[1] if len(sys.argv) > 1 else "sess"
    question = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else "Pergunta?"
    ans, cites, qhash = chat_respond(sess, question)
    print(json.dumps({"answer": ans, "cites": cites, "query_hash": qhash}, ensure_ascii=False))
