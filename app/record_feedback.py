import argparse
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_API = os.getenv("API_URL") or f"http://127.0.0.1:{os.getenv('API_PORT', '18888')}"


def post_feedback(api_url: str, query_hash: str, doc_id: int, signal: int) -> dict:
    payload = json.dumps({
        "query_hash": query_hash,
        "doc_id": doc_id,
        "signal": signal,
    }).encode("utf-8")
    url = api_url.rstrip("/") + "/feedback"
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = resp.read().decode("utf-8")
        if not body:
            return {"ok": resp.status < 300, "status": resp.status}
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return {"ok": resp.status < 300, "status": resp.status, "raw": body}
        data.setdefault("status", resp.status)
        return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Enviar feedback de relevância para a API da Sophia.")
    parser.add_argument("query_hash", help="Hash da pergunta (sha256)")
    parser.add_argument("doc_id", type=int, help="ID do chunk (docs.id)")
    parser.add_argument("signal", type=int, choices=[-1, 0, 1], help="Sinal do feedback")
    parser.add_argument("--api-url", dest="api_url", default=DEFAULT_API, help="Endpoint base da API (default: %(default)s)")
    args = parser.parse_args(argv)

    try:
        result = post_feedback(args.api_url, args.query_hash, args.doc_id, args.signal)
    except urllib.error.URLError as exc:
        print(f"Falha ao enviar feedback: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
