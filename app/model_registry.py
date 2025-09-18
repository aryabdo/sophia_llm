import json, os, sys
from pathlib import Path
from dotenv import load_dotenv

APP_DIR = Path(__file__).parent
ENV_P = APP_DIR / ".env"
REG_P = APP_DIR / "models.json"
if not ENV_P.exists():
    ENV_P.write_text("", encoding="utf-8")
load_dotenv(ENV_P, override=True)

def load_env(): return ENV_P.read_text(encoding="utf-8").splitlines()
def save_env(lines): ENV_P.write_text("\n".join(lines) + "\n", encoding="utf-8")

def set_env(key, val):
    lines = load_env(); found = False
    for i, L in enumerate(lines):
        if L.startswith(f"{key}="):
            lines[i] = f"{key}={val}"; found = True; break
    if not found: lines.append(f"{key}={val}")
    save_env(lines)

def get_current():
    if REG_P.exists(): d = json.loads(REG_P.read_text(encoding="utf-8"))
    else: d = {"current": None, "prev": None}
    return d

def set_current(model_id):
    d = get_current(); d["prev"] = d.get("current"); d["current"] = model_id
    REG_P.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
    set_env("GEN_MODEL", model_id or os.getenv("FINETUNE_BASE","gpt-4o-mini"))
    return d

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv)>1 else ""
    if cmd == "use":
        mid = sys.argv[2] if len(sys.argv)>2 else ""
        print(json.dumps(set_current(mid), ensure_ascii=False))
    elif cmd == "rollback":
        d = get_current()
        prev = d.get("prev")
        if prev: print(json.dumps(set_current(prev), ensure_ascii=False))
        else: print(json.dumps({"error":"sem prev"}, ensure_ascii=False))
    else:
        print(json.dumps(get_current(), ensure_ascii=False))
