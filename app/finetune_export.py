from pathlib import Path
import os, json, random, math
from datetime import datetime
import psycopg
from psycopg.rows import dict_row
from dotenv import load_dotenv

APP_DIR = Path(__file__).parent
load_dotenv(APP_DIR / ".env", override=True)

DB_URL = os.getenv("DATABASE_URL")
FINETUNE_DIR = Path(os.getenv("FINETUNE_DIR", "/opt/rag-sophia/finetune"))
VAL_SPLIT = float(os.getenv("FINETUNE_VAL_SPLIT", "0.1"))
SEED = int(os.getenv("FINETUNE_SEED", "42"))

FINETUNE_DIR.mkdir(parents=True, exist_ok=True)

def _msg(system, user, assistant):
    return {"messages":[
        {"role":"system","content": system},
        {"role":"user","content": user},
        {"role":"assistant","content": assistant},
    ]}

SYSTEM_PROMPT = ("Você é um analista jurídico-regulatório. Responda usando apenas o contexto, "
                 "cite fontes como [#n] + caminho e diga 'falta base' quando faltar.")

def fetch(conn):
    out = []
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute("SELECT question, answer, citations FROM qa_cache ORDER BY created_at DESC LIMIT 5000;")
        for r in cur.fetchall():
            q = (r["question"] or "").strip()
            a = (r["answer"] or "").strip()
            if not q or not a: continue
            out.append(_msg(SYSTEM_PROMPT, q, a))
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute("SELECT path, summary, pros, cons FROM doc_analysis ORDER BY created_at DESC LIMIT 5000;")
        for r in cur.fetchall():
            path = r["path"]
            summ = (r.get("summary") or "").strip()
            pros = r.get("pros") or []
            cons = r.get("cons") or []
            if summ:
                user = f"Resuma criticamente o documento e cite [#] com caminhos.\nDocumento: {path}"
                out.append(_msg(SYSTEM_PROMPT, user, summ))
            if pros or cons:
                user = f"Liste prós e contras fundamentados de {path} com citações [#]."
                as_lines=[]
                if pros:
                    as_lines.append("**Prós:**")
                    for it in pros[:10]:
                        as_lines.append(f"- {it.get('claim','')} — {it.get('why','')}")
                if cons:
                    as_lines.append("**Contras:**")
                    for it in cons[:10]:
                        as_lines.append(f"- {it.get('claim','')} — {it.get('why','')}")
                out.append(_msg(SYSTEM_PROMPT, user, "\n".join(as_lines)))
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute("SELECT text FROM notes ORDER BY created_at DESC LIMIT 1000;")
        for r in cur.fetchall():
            t = (r["text"] or "").strip()
            if t:
                user = "Explique a nota abaixo e aponte 'falta base' se não houver citação suficiente.\nNota:\n" + t
                out.append(_msg(SYSTEM_PROMPT, user, "falta base"))
    return out

def main():
    random.seed(SEED)
    with psycopg.connect(DB_URL) as conn:
        data = fetch(conn)
    random.shuffle(data)
    n = len(data)
    n_val = max(1, math.floor(n * VAL_SPLIT)) if n > 10 else 1
    train = data[n_val:]
    val = data[:n_val]
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    train_p = FINETUNE_DIR / f"train_{ts}.jsonl"
    val_p   = FINETUNE_DIR / f"val_{ts}.jsonl"
    with train_p.open("w", encoding="utf-8") as f:
        for ex in train: f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    with val_p.open("w", encoding="utf-8") as f:
        for ex in val: f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    (FINETUNE_DIR / "train.jsonl").unlink(missing_ok=True)
    (FINETUNE_DIR / "val.jsonl").unlink(missing_ok=True)
    (FINETUNE_DIR / "train.jsonl").symlink_to(train_p.name)
    (FINETUNE_DIR / "val.jsonl").symlink_to(val_p.name)
    print(json.dumps({"ok": True, "train": str(train_p), "val": str(val_p), "n": n, "val_split": n_val}, ensure_ascii=False))

if __name__ == "__main__":
    main()
