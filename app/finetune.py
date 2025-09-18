"""Ferramentas para acionar fine-tuning do modelo conversacional.

Este módulo lê os arquivos JSONL presentes em ``FINETUNE_DIR`` e cria jobs de
fine-tuning usando o provedor configurado (atualmente, via API compatível com a
biblioteca ``openai``). Ele também permite consultar o status de jobs
existentes, útil para acompanhar o progresso e automatizar rotinas de
atualização de modelo.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Tuple

from openai import OpenAI

FINETUNE_DIR = Path(os.getenv("FINETUNE_DIR", "finetune"))
FINETUNE_BASE = os.getenv("FINETUNE_BASE")
FINETUNE_HISTORY = Path(
    os.getenv("FINETUNE_HISTORY", FINETUNE_DIR / "history.jsonl")
)
POLL_SECONDS = int(os.getenv("FINETUNE_POLL_SECONDS", "10"))


def _to_dict(obj):
    """Convert helper that works across SDK versions."""

    if hasattr(obj, "model_dump"):
        return obj.model_dump()
    if hasattr(obj, "to_dict"):
        return obj.to_dict()
    if isinstance(obj, dict):
        return obj
    try:
        return json.loads(json.dumps(obj, default=lambda o: getattr(o, "__dict__", str(o))))
    except TypeError:
        return {"repr": repr(obj)}


def _normalise_record(record: dict) -> dict:
    """Ensure the record follows the chat fine-tuning schema."""

    if "messages" in record and isinstance(record["messages"], list):
        return {"messages": record["messages"]}

    question = record.get("question") or record.get("prompt")
    answer = record.get("answer") or record.get("completion")
    if not question or not answer:
        raise ValueError("registro precisa ter question/prompt e answer/completion")

    messages = []
    system_msg = record.get("system")
    if system_msg:
        messages.append({"role": "system", "content": str(system_msg)})
    messages.append({"role": "user", "content": str(question)})
    messages.append({"role": "assistant", "content": str(answer)})
    return {"messages": messages}


def _collect_records(directory: Path) -> Tuple[list[dict], list[str]]:
    if not directory.exists():
        raise FileNotFoundError(f"FINETUNE_DIR '{directory}' não encontrado")

    records: list[dict] = []
    sources: list[str] = []
    for path in sorted(directory.glob("*.jsonl")):
        with path.open("r", encoding="utf-8") as handle:
            for lineno, raw in enumerate(handle, start=1):
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    obj = json.loads(raw)
                except json.JSONDecodeError as exc:
                    raise ValueError(f"JSON inválido em {path}:{lineno}: {exc}") from exc
                try:
                    norm = _normalise_record(obj)
                except ValueError as exc:
                    raise ValueError(f"Dados incompletos em {path}:{lineno}: {exc}") from exc
                records.append(norm)
        sources.append(str(path))
    return records, sources


def _write_dataset(records: Iterable[dict]) -> Path:
    tmp = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8")
    with tmp as handle:
        for rec in records:
            handle.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return Path(tmp.name)


def _append_history(entry: dict) -> None:
    FINETUNE_HISTORY.parent.mkdir(parents=True, exist_ok=True)
    with FINETUNE_HISTORY.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


def _start_job(client: OpenAI, watch: bool = False) -> dict:
    if not FINETUNE_BASE:
        raise RuntimeError("FINETUNE_BASE não configurado")
    records, sources = _collect_records(FINETUNE_DIR)
    if not records:
        raise RuntimeError(f"Nenhum dado encontrado em {FINETUNE_DIR}")

    dataset_path = _write_dataset(records)
    try:
        upload = client.files.create(file=open(dataset_path, "rb"), purpose="fine-tune")
        job = client.fine_tuning.jobs.create(
            model=FINETUNE_BASE,
            training_file=upload.id,
        )
    finally:
        try:
            dataset_path.unlink()
        except FileNotFoundError:
            pass

    job_dict = _to_dict(job)
    entry = {
        "job_id": job.id,
        "status": job.status,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "training_file": getattr(upload, "id", None),
        "records": len(records),
        "sources": sources,
    }
    _append_history(entry)

    if watch:
        job_dict = _watch_job(client, job.id)

    result = {
        "job": job_dict,
        "history_entry": entry,
    }
    return result


def _watch_job(client: OpenAI, job_id: str) -> dict:
    status = None
    job_dict = {}
    while status not in {"succeeded", "failed", "cancelled"}:
        job = client.fine_tuning.jobs.retrieve(job_id)
        job_dict = _to_dict(job)
        status = job_dict.get("status")
        if status in {"succeeded", "failed", "cancelled"}:
            break
        time.sleep(POLL_SECONDS)
    return job_dict


def _status_job(client: OpenAI, job_id: str, watch: bool = False) -> dict:
    if watch:
        job_dict = _watch_job(client, job_id)
    else:
        job = client.fine_tuning.jobs.retrieve(job_id)
        job_dict = _to_dict(job)

    events_resp = client.fine_tuning.jobs.list_events(job_id, limit=50)
    events = [_to_dict(ev) for ev in getattr(events_resp, "data", [])]
    return {"job": job_dict, "events": events}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Gerenciar jobs de fine-tuning do modelo de QA")
    parser.add_argument("--status", dest="status", help="Consultar job existente")
    parser.add_argument("--watch", dest="watch", action="store_true", help="Aguardar conclusão do job")
    args = parser.parse_args(argv)

    client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

    try:
        if args.status:
            result = _status_job(client, args.status, watch=args.watch)
        else:
            result = _start_job(client, watch=args.watch)
    except Exception as exc:  # pragma: no cover - script style
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        return 1

    print(json.dumps({"ok": True, **result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry
    sys.exit(main())
