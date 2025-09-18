import os, json, time, sys
from pathlib import Path
from dotenv import load_dotenv
from openai import OpenAI
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Json

APP_DIR = Path(__file__).parent
load_dotenv(APP_DIR / ".env", override=True)

DB_URL = os.getenv("DATABASE_URL")
FINETUNE_DIR = Path(os.getenv("FINETUNE_DIR","/opt/rag-sophia/finetune"))
BASE = os.getenv("FINETUNE_BASE","gpt-4o-mini")

def upsert_run(conn, **k):
    cols = ",".join(k.keys()); vals = tuple(k.values()); placeholders = ",".join(["%s"]*len(k))
    with conn.cursor() as cur:
        cur.execute(f"INSERT INTO finetune_runs({cols}) VALUES({placeholders}) RETURNING id;", vals)
        rid = cur.fetchone()[0]; conn.commit()
    return rid

def update_run(conn, rid, **k):
    sets = []
    vals = []
    for c, v in k.items():
        if isinstance(v, str) and v.strip().lower() == "now()":
            sets.append(f"{c}=now()")
        else:
            sets.append(f"{c}=%s")
            vals.append(v)
    vals.append(rid)
    sets_clause = ",".join(sets)
    with conn.cursor() as cur:
        cur.execute(f"UPDATE finetune_runs SET {sets_clause} WHERE id=%s", tuple(vals)); conn.commit()

def main():
    client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
    train_p = FINETUNE_DIR / "train.jsonl"; val_p = FINETUNE_DIR / "val.jsonl"
    if not train_p.exists() or not val_p.exists():
        print("datasets ausentes; rode finetune_export.py", file=sys.stderr); sys.exit(2)
    with psycopg.connect(DB_URL, row_factory=dict_row) as conn:
        f_train = client.files.create(file=open(train_p,"rb"), purpose="fine-tune")
        f_val   = client.files.create(file=open(val_p,"rb"),   purpose="fine-tune")
        rid = upsert_run(
            conn,
            provider="openai",
            base_model=BASE,
            status="queued",
            train_file_id=f_train.id,
            val_file_id=f_val.id,
            params=Json({}),
        )
        job = client.fine_tuning.jobs.create(training_file=f_train.id, validation_file=f_val.id, model=BASE)
        update_run(conn, rid, job_id=job.id, status=job.status)
        while True:
            info = client.fine_tuning.jobs.retrieve(job.id)
            st = info.status
            if st in ("succeeded","failed","cancelled"):
                model_id = getattr(info, "fine_tuned_model", None)
                update_run(conn, rid, status=st, trained_model_id=model_id, finished_at="now()")
                print(json.dumps({"status": st, "model_id": model_id, "job_id": job.id}, ensure_ascii=False))
                break
            time.sleep(10)

if __name__ == "__main__":
    main()
