"""
End-to-end test for the backend: starts a real server, downloads small models,
chats with them, compares token counts, judges answers and checks cancellation.

Run: ~/airllm/.venv/bin/python tests/test_backend_e2e.py
"""

import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS = Path(os.environ.get("MP_TEST_MODELS", Path.home() / "ModelPlayground" / "models"))
SMALL = ["mlx-community/Qwen3-0.6B-4bit", "mlx-community/LFM2.5-1.2B-Instruct-4bit"]

results = []


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


PORT = free_port()
BASE = f"http://127.0.0.1:{PORT}"


def req(method, path, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return resp.status, resp.read()


def get(path):
    return json.loads(req("GET", path)[1])


def post(path, body, timeout=60):
    return json.loads(req("POST", path, body, timeout)[1])


def stream(path, body, timeout=600, on_event=None):
    r = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST",
                               headers={"Content-Type": "application/json"})
    events = []
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        for line in resp:
            if line.strip():
                ev = json.loads(line)
                events.append(ev)
                if on_event and on_event(ev) is False:
                    break
    return events


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def main():
    proc = subprocess.Popen([sys.executable, str(ROOT / "backend" / "server.py"), "--port", str(PORT)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        for _ in range(60):
            try:
                h = get("/health")
                break
            except Exception:
                time.sleep(0.5)
        else:
            check("server starts", False, proc.stdout.read().decode()[-2000:])
            return
        check("health identifies the app", h.get("app") == "model-playground", str(h))

        cat = get("/catalog")
        check("catalog has 60+ models", len(cat) >= 60, f"{len(cat)} entries")
        check("catalog entries have context sizes", all(c["context"] > 0 for c in cat))

        sysinfo = get("/system?folder=" + str(MODELS))
        check("system info", sysinfo["total_ram_gb"] > 0, str(sysinfo))

        # Downloads (skipped when already present).
        for repo in SMALL:
            post("/download", {"repo_id": repo, "folder": str(MODELS)})
        deadline = time.time() + 900
        while time.time() < deadline:
            jobs = [j for j in get("/downloads") if j["repo_id"] in SMALL]
            if all(j["status"] in ("done", "error") for j in jobs):
                break
            time.sleep(2)
        check("downloads finish", all(j["status"] == "done" for j in jobs),
              "; ".join(f"{j['repo_id']}={j['status']} {j['error'] or ''}" for j in jobs))
        check("download progress reaches total", all(j["downloaded"] >= j["total"] * 0.99 for j in jobs))

        models = get("/models?folder=" + str(MODELS))
        by_repo = {m["repo_id"]: m for m in models}
        check("downloaded models are listed", all(r in by_repo for r in SMALL), ", ".join(by_repo))
        check("hf cache models are listed", any(m["source"] == "hf-cache" for m in models))

        # Chat with each small model.
        answers = {}
        for repo in SMALL:
            m = by_repo[repo]
            text = ""
            done = None
            for ev in stream("/chat", {"model_path": m["path"], "model_name": m["name"], "engine": "mlx",
                                       "messages": [{"role": "user", "content": "What is 12 * 12? Answer in one short sentence."}],
                                       "max_tokens": 200, "temperature": 0, "thinking": False}):
                if ev["type"] == "token":
                    text += ev["text"]
                elif ev["type"] == "done":
                    done = ev["stats"]
                elif ev["type"] == "error":
                    check(f"chat {m['name']}", False, ev["message"])
            answers[repo] = text
            check(f"chat {m['name']} streams an answer", "144" in text, repr(text[-120:]))
            check(f"chat {m['name']} reports stats", done and done["generation_tokens"] > 0 and done["tokens_per_second"] > 0,
                  f"{done['tokens_per_second'] if done else 0} tok/s, {done['generation_tokens'] if done else 0} tokens")

        # Multi-turn context.
        m = by_repo[SMALL[0]]
        text = "".join(ev.get("text", "") for ev in stream("/chat", {
            "model_path": m["path"], "engine": "mlx", "temperature": 0, "max_tokens": 120, "thinking": False,
            "kv_bits": 8,
            "messages": [{"role": "user", "content": "My name is Zorblat. Remember it."},
                         {"role": "assistant", "content": "Got it, Zorblat."},
                         {"role": "user", "content": "What is my name?"}]}) if ev["type"] == "token")
        check("multi-turn context with 8-bit KV cache", "zorblat" in text.lower(), repr(text[-120:]))

        # Token count comparison across tokenizers.
        tk = post("/tokenize", {"paths": [by_repo[r]["path"] for r in SMALL], "text": "The quick brown fox jumps over the lazy dog. " * 20})
        counts = list(tk["counts"].values())
        check("tokenize counts per model", all(isinstance(c, int) and c > 0 for c in counts), str(tk["counts"]))

        # Quality judge.
        scores = None
        judge_events = stream("/judge", {"judge_path": by_repo[SMALL[0]]["path"], "engine": "mlx",
                                         "prompt": "What is 12 * 12?",
                                         "answers": [{"id": "a", "text": answers[SMALL[0]]},
                                                     {"id": "b", "text": "12 times 12 is 100."}]})
        for ev in judge_events:
            if ev["type"] == "done":
                scores = ev["scores"]
        check("judge returns a score per answer", scores and len(scores) == 2, json.dumps(scores)[:300] if scores else "none")
        check("judge scores are in range", scores and all(0 < s["overall"] <= 10 for s in scores),
              ", ".join(f"{s['id']}={s['overall']}" for s in (scores or [])))

        # Benchmarks: quiz grading and long-context retrieval.
        evs = stream("/eval", {"model_path": by_repo[SMALL[0]]["path"], "suites": ["quick", "needle"],
                               "needle_lengths": [1000, 2000], "needle_depths": [0.5], "model_context": 32768})
        res = [e["result"] for e in evs if e["type"] == "result"]
        quiz = [r for r in res if r["suite"] == "quick"]
        needle = [r for r in res if r["suite"] == "needle"]
        check("eval grades the quiz", len(quiz) == 13, f"{sum(r['passed'] for r in quiz)}/{len(quiz)} passed")
        check("eval runs the context test", len(needle) == 2 and all(r["context_tokens"] >= 900 for r in needle),
              ", ".join(f"{r['label']}={'pass' if r['passed'] else 'fail'}" for r in needle))
        check("catalog has powerful 32GB+ models", any(c["family"].startswith("Powerful") for c in cat)
              and any(c["family"].startswith("Frontier") for c in cat))

        # Cancellation: stop after a few tokens and confirm the worker is free again.
        got = {"n": 0}

        def on_ev(ev):
            if ev["type"] == "token":
                got["n"] += 1
                if got["n"] == 5:
                    post("/stop", {})
        evs = stream("/chat", {"model_path": m["path"], "engine": "mlx", "max_tokens": 2000,
                               "messages": [{"role": "user", "content": "Write a very long story about the sea."}]},
                     on_event=on_ev)
        done = next((e for e in evs if e["type"] == "done"), None)
        check("stop cancels generation", done and done["stats"]["finish_reason"] == "cancelled",
              f"{done['stats']['generation_tokens'] if done else '?'} tokens")
        check("worker is idle after stop", get("/health")["busy"] is False)

        # Error handling.
        try:
            req("POST", "/chat", {"model_path": "/nonexistent", "messages": []})
            check("missing model returns 404", False)
        except urllib.error.HTTPError as e:
            check("missing model returns 404", e.code == 404)

        post("/unload", {})
        check("unload frees the model", get("/health")["loaded"] is None)
    finally:
        proc.terminate()
        proc.wait(timeout=10)

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
