"""
Model Playground backend.

A local HTTP server that the Mac app launches. It lists, downloads, runs, compares and
judges open-source LLMs with two engines:

  * mlx    - mlx-lm, fast on Apple Silicon, runs most architectures (Qwen, Llama, Gemma, ...)
  * airllm - AirLLM, streams layers from disk so models larger than RAM can run (slow, Llama only)

All model work happens on one dedicated worker thread, because MLX state is not
safe to share across threads and only one model fits in memory at a time anyway.
"""

import argparse
import fnmatch
import gc
import json
import os
import queue
import re
import shutil
import threading
import time
import uuid
from pathlib import Path

import psutil
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

# Xet transfers buffer whole files before writing them, which hides download progress.
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

APP_ID = "model-playground"
VERSION = "1.0.0"
HF_CACHE = Path(os.environ.get("HF_HUB_CACHE", Path.home() / ".cache" / "huggingface" / "hub"))

# Curated catalog. Every repo here was checked to exist on Hugging Face.
# family, repo, params, download size (GB), native context (tokens), engine, notes
CATALOG = [
    # Long-context picks for a 16 GB Mac: biggest models that still leave room for a large KV cache.
    ("Long context", "mlx-community/Qwen3.5-9B-4bit", "9B", 5.98, 262144, "mlx", "Newest Qwen, 256K window. Best overall pick for 16 GB"),
    ("Long context", "mlx-community/Qwen2.5-7B-Instruct-1M-4bit", "7B", 4.30, 1010000, "mlx", "1M-token window for very long documents"),
    ("Long context", "mlx-community/Qwen3-4B-Instruct-2507-4bit", "4B", 2.28, 262144, "mlx", "Small and fast with a 256K window"),
    ("Long context", "mlx-community/Mistral-Nemo-Instruct-2407-4bit", "12B", 6.91, 131072, "mlx", "12B with 128K context"),
    ("Long context", "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", "8B", 4.53, 131072, "mlx", "Meta's 128K baseline"),
    ("Long context", "mlx-community/LFM2.5-8B-A1B-MLX-4bit", "8B MoE", 4.78, 128000, "mlx", "Liquid AI MoE, very fast for its size"),
    # Large: highest quality that fits in 16 GB, at the cost of context headroom.
    ("Large", "mlx-community/Qwen3-14B-4bit", "14B", 8.32, 32768, "mlx", "Best quality on 16 GB, tight fit"),
    ("Large", "mlx-community/Qwen3-14B-3bit", "14B", 6.48, 32768, "mlx", "14B at 3-bit, more memory left for context"),
    ("Large", "mlx-community/Qwen2.5-14B-Instruct-4bit", "14B", 8.32, 32768, "mlx", "Strong 14B generalist"),
    ("Large", "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit", "14B", 8.32, 131072, "mlx", "14B reasoning distill"),
    ("Large", "mlx-community/gemma-3-12b-it-4bit", "12B", 8.07, 131072, "mlx", "Google 12B, 128K context"),
    ("Large", "mlx-community/phi-4-4bit", "14B", 8.26, 16384, "mlx", "Microsoft 14B"),
    ("Large", "mlx-community/Falcon3-10B-Instruct-4bit", "10B", 5.81, 32768, "mlx", "TII Falcon 3"),
    ("Large", "mlx-community/Mistral-Small-24B-Instruct-2501-3bit", "24B", 10.33, 32768, "mlx", "24B at 3-bit, very tight on 16 GB"),
    ("Large", "mlx-community/gpt-oss-20b-MXFP4-Q4", "20B", 11.21, 131072, "mlx", "OpenAI open weights, may exceed GPU memory"),
    ("Large", "mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit-REAP-14B", "26B MoE", 11.24, 262144, "mlx", "Pruned Gemma 4 MoE, may exceed GPU memory"),
    ("Large", "mlx-community/Qwen3-30B-A3B-3bit", "30B MoE", 13.37, 32768, "mlx", "Needs more than 16 GB"),
    ("Large", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-3bit", "30B MoE", 13.37, 262144, "mlx", "Needs more than 16 GB"),
    # Qwen
    ("Qwen", "mlx-community/Qwen3.5-0.8B-OptiQ-4bit", "0.8B", 0.89, 262144, "mlx", "Qwen 3.5, tiny"),
    ("Qwen", "mlx-community/Qwen3.5-2B-OptiQ-4bit", "2B", 2.26, 262144, "mlx", "Qwen 3.5, small"),
    ("Qwen", "mlx-community/Qwen3.5-4B-4bit", "4B", 3.06, 262144, "mlx", "Qwen 3.5, strong for its size"),
    ("Qwen", "mlx-community/Qwen3-0.6B-4bit", "0.6B", 0.35, 32768, "mlx", "Tiny, very fast, thinks before answering"),
    ("Qwen", "mlx-community/Qwen3-1.7B-4bit", "1.7B", 0.98, 32768, "mlx", "Small reasoning model"),
    ("Qwen", "mlx-community/Qwen3-4B-4bit", "4B", 2.28, 32768, "mlx", "Hybrid thinking"),
    ("Qwen", "mlx-community/Qwen3-4B-Thinking-2507-4bit", "4B", 2.28, 262144, "mlx", "Always reasons step by step"),
    ("Qwen", "mlx-community/Qwen3-8B-4bit", "8B", 4.62, 32768, "mlx", "Quick and capable"),
    ("Qwen", "mlx-community/Qwen2.5-0.5B-Instruct-4bit", "0.5B", 0.29, 32768, "mlx", "Smallest instruct model here"),
    ("Qwen", "mlx-community/Qwen2.5-1.5B-Instruct-4bit", "1.5B", 0.88, 32768, "mlx", "Fast general chat"),
    ("Qwen", "mlx-community/Qwen2.5-7B-Instruct-4bit", "7B", 4.30, 32768, "mlx", "Solid general chat"),
    ("Qwen", "mlx-community/Qwen2.5-Math-7B-Instruct-4bit", "7B", 4.30, 4096, "mlx", "Math specialist"),
    # Coding
    ("Coding", "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit", "1.5B", 0.88, 32768, "mlx", "Small coding model"),
    ("Coding", "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", "7B", 4.30, 32768, "mlx", "Good coding model"),
    ("Coding", "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit", "14B", 8.32, 32768, "mlx", "Strong coder, tight fit"),
    # Reasoning
    ("Reasoning", "mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit", "8B", 4.62, 131072, "mlx", "DeepSeek R1 distilled into Qwen 3"),
    ("Reasoning", "mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit", "1.5B", 1.01, 131072, "mlx", "Tiny reasoning distill"),
    ("Reasoning", "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit", "7B", 4.30, 131072, "mlx", "Reasoning distill"),
    ("Reasoning", "mlx-community/phi-4-mini-reasoning-4bit", "3.8B", 2.18, 131072, "mlx", "Microsoft, math reasoning"),
    # Llama
    ("Llama", "mlx-community/Llama-3.2-1B-Instruct-4bit", "1B", 0.71, 131072, "mlx", "Meta, tiny, long context"),
    ("Llama", "mlx-community/Llama-3.2-3B-Instruct-4bit", "3B", 1.82, 131072, "mlx", "Meta, small, long context"),
    ("Llama", "mlx-community/Llama-3.2-3B-Instruct-8bit", "3B", 3.42, 131072, "mlx", "8-bit, closer to full quality"),
    ("Llama", "mlx-community/Hermes-3-Llama-3.1-8B-4bit", "8B", 4.53, 131072, "mlx", "Nous Research fine-tune"),
    # Gemma
    ("Gemma", "mlx-community/gemma-3-1b-it-4bit", "1B", 0.77, 32768, "mlx", "Google, tiny"),
    ("Gemma", "mlx-community/gemma-2-2b-it-4bit", "2B", 1.49, 8192, "mlx", "Google, small"),
    ("Gemma", "mlx-community/gemma-3-4b-it-4bit", "4B", 3.44, 131072, "mlx", "Google, long context"),
    ("Gemma", "mlx-community/gemma-2-9b-it-4bit", "9B", 5.22, 8192, "mlx", "Google Gemma 2"),
    ("Gemma", "mlx-community/gemma-4-e2b-it-qat-OptiQ-4bit", "E2B", 5.25, 131072, "mlx", "Gemma 4 edge model"),
    ("Gemma", "mlx-community/gemma-4-e4b-it-qat-OptiQ-4bit", "E4B", 7.51, 131072, "mlx", "Gemma 4 edge model, larger"),
    # Mistral
    ("Mistral", "mlx-community/Mistral-7B-Instruct-v0.3-4bit", "7B", 4.08, 32768, "mlx", "Mistral AI classic"),
    ("Mistral", "mlx-community/Ministral-8B-Instruct-2410-4bit", "8B", 4.54, 32768, "mlx", "Ministral 8B"),
    # Microsoft
    ("Phi", "mlx-community/Phi-3.5-mini-instruct-4bit", "3.8B", 2.15, 131072, "mlx", "Compact, long context"),
    ("Phi", "mlx-community/Phi-4-mini-instruct-4bit", "3.8B", 2.18, 131072, "mlx", "Phi 4 mini"),
    # Small and efficient
    ("Small & fast", "mlx-community/LFM2.5-1.2B-Instruct-4bit", "1.2B", 0.66, 128000, "mlx", "Liquid AI, very fast"),
    ("Small & fast", "mlx-community/LFM2.5-2.6B-4bit", "2.6B", 1.54, 128000, "mlx", "Liquid AI"),
    ("Small & fast", "mlx-community/SmolLM3-3B-4bit", "3B", 1.75, 65536, "mlx", "Hugging Face, fully open"),
    ("Small & fast", "mlx-community/granite-4.0-h-micro-4bit", "3B", 1.81, 131072, "mlx", "IBM Granite 4 hybrid"),
    ("Small & fast", "mlx-community/granite-3.3-2b-instruct-4bit", "2B", 1.43, 131072, "mlx", "IBM Granite 3.3"),
    ("Small & fast", "mlx-community/EXAONE-3.5-2.4B-Instruct-4bit", "2.4B", 1.36, 32768, "mlx", "LG AI Research"),
    # Other labs
    ("More labs", "mlx-community/GLM-4-9B-0414-4bit", "9B", 5.31, 32768, "mlx", "Zhipu GLM-4"),
    ("More labs", "mlx-community/OLMo-2-1124-7B-Instruct-4bit", "7B", 4.12, 4096, "mlx", "AI2, fully open data"),
    ("More labs", "mlx-community/Falcon3-7B-Instruct-4bit", "7B", 4.20, 32768, "mlx", "TII Falcon 3"),
    ("More labs", "mlx-community/EXAONE-3.5-7.8B-Instruct-4bit", "7.8B", 4.41, 32768, "mlx", "LG AI Research"),
    ("More labs", "mlx-community/aya-expanse-8b-4bit", "8B", 4.54, 8192, "mlx", "Cohere, 23 languages"),
    # Powerful: frontier-class open models. They need a Mac with more unified memory than 16 GB.
    ("Powerful (24 GB+)", "mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit", "24B", 13.3, 131072, "mlx", "Mistral Small 3.2, 128K context"),
    ("Powerful (24 GB+)", "mlx-community/gemma-3-27b-it-4bit", "27B", 16.9, 131072, "mlx", "Google Gemma 3 27B"),
    ("Powerful (32 GB+)", "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", "30B MoE", 17.2, 262144, "mlx", "Fast MoE with 256K context"),
    ("Powerful (32 GB+)", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "30B MoE", 17.2, 262144, "mlx", "Top open coding model at this size"),
    ("Powerful (32 GB+)", "mlx-community/Qwen3-32B-4bit", "32B", 18.4, 40960, "mlx", "Dense 32B, strong reasoning"),
    ("Powerful (32 GB+)", "mlx-community/QwQ-32B-4bit", "32B", 18.4, 131072, "mlx", "Qwen reasoning model"),
    ("Powerful (32 GB+)", "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit", "32B", 18.4, 131072, "mlx", "DeepSeek R1 distill, 32B"),
    ("Powerful (32 GB+)", "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit", "32B", 18.4, 32768, "mlx", "Qwen 2.5 Coder 32B"),
    ("Powerful (32 GB+)", "mlx-community/Qwen3.6-27B-OptiQ-4bit", "27B", 20.0, 262144, "mlx", "Newest Qwen dense model"),
    ("Powerful (32 GB+)", "mlx-community/gemma-4-26B-A4B-it-qat-OptiQ-4bit", "26B MoE", 21.9, 262144, "mlx", "Gemma 4 MoE, 256K context"),
    ("Powerful (32 GB+)", "mlx-community/gemma-4-31B-it-qat-OptiQ-4bit", "31B", 23.6, 262144, "mlx", "Gemma 4 flagship dense"),
    ("Powerful (32 GB+)", "mlx-community/Qwen3.6-35B-A3B-OptiQ-4bit", "35B MoE", 24.7, 262144, "mlx", "Newest Qwen MoE, fast"),
    ("Powerful (24 GB+)", "mlx-community/Qwen3.6-35B-A3B-OptiQ-4bit-REAP-19B", "35B MoE", 14.9, 262144, "mlx", "Pruned Qwen 3.6 MoE, smartest that fits 24 GB"),
    ("Powerful (24 GB+)", "mlx-community/Devstral-Small-2507-4bit", "24B", 13.3, 131072, "mlx", "Mistral's agentic coding model"),
    ("Powerful (24 GB+)", "mlx-community/Qwen3.5-27B-4bit", "27B", 16.1, 262144, "mlx", "Qwen 3.5 dense 27B"),
    ("Powerful (32 GB+)", "mlx-community/Qwen3.5-35B-A3B-4bit", "35B MoE", 20.4, 262144, "mlx", "Qwen 3.5 MoE, fast and smart"),
    ("Powerful (32 GB+)", "mlx-community/Seed-OSS-36B-Instruct-4bit", "36B", 20.3, 524288, "mlx", "ByteDance Seed, 512K context"),
    ("Frontier (64 GB+)", "mlx-community/Llama-3.3-70B-Instruct-4bit", "70B", 39.7, 131072, "mlx", "Meta Llama 3.3 70B"),
    ("Frontier (64 GB+)", "mlx-community/DeepSeek-R1-Distill-Llama-70B-4bit", "70B", 39.7, 131072, "mlx", "DeepSeek R1 distill, 70B"),
    ("Frontier (64 GB+)", "mlx-community/Qwen2.5-72B-Instruct-4bit", "72B", 40.9, 32768, "mlx", "Qwen 2.5 72B"),
    ("Frontier (64 GB+)", "mlx-community/GLM-4.5-Air-4bit", "106B MoE", 60.2, 131072, "mlx", "Zhipu GLM 4.5 Air"),
    ("Frontier (64 GB+)", "mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit", "109B MoE", 61.1, 10485760, "mlx", "Meta Llama 4 Scout, 10M context"),
    ("Frontier (64 GB+)", "mlx-community/gpt-oss-120b-MXFP4-Q4", "120B MoE", 62.4, 131072, "mlx", "OpenAI gpt-oss 120B"),
    ("Meta Muse", "mlx-community/Muse-Glimmer-30B-mxfp4", "30B", 18.6, 131072, "mlx", "Meta Muse Glimmer, MXFP4, smallest build"),
    ("Meta Muse", "mlx-community/Muse-Glimmer-30B-4bit", "30B", 19.4, 131072, "mlx", "Meta Muse Glimmer 30B, 128K context"),
    ("Meta Muse", "mlx-community/Muse-Glimmer-30B-8bit", "30B", 33.4, 131072, "mlx", "Meta Muse Glimmer, near full quality"),
    ("Meta Muse", "mlx-community/Muse-Glimmer-30B-bf16", "30B", 59.6, 131072, "mlx", "Meta Muse Glimmer, full precision"),
    ("Frontier (64 GB+)", "mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit", "80B MoE", 44.9, 262144, "mlx", "Qwen3-Next, hybrid attention, very fast"),
    ("Frontier (64 GB+)", "mlx-community/Qwen3-Next-80B-A3B-Thinking-4bit", "80B MoE", 44.9, 262144, "mlx", "Qwen3-Next reasoning"),
    ("Frontier (64 GB+)", "mlx-community/Hermes-4-70B-4bit", "70B", 39.7, 131072, "mlx", "Nous Hermes 4 on Llama 3.1 70B"),
    ("Frontier (96 GB+)", "mlx-community/Qwen3.5-122B-A10B-4bit", "122B MoE", 69.6, 262144, "mlx", "Qwen 3.5 large MoE"),
    ("Frontier (128 GB+)", "mlx-community/DeepSeek-V4-Flash-2bit-DQ", "MoE", 96.5, 1048576, "mlx", "DeepSeek V4 Flash, 1M context, 2-bit"),
    ("Frontier (192 GB+)", "mlx-community/MiniMax-M2-4bit", "230B MoE", 128.7, 196608, "mlx", "MiniMax M2, strong agentic coder"),
    ("Frontier (192 GB+)", "mlx-community/Qwen3-235B-A22B-Instruct-2507-4bit", "235B MoE", 132.3, 262144, "mlx", "Qwen 3 flagship, 2507 update"),
    ("Frontier (192 GB+)", "mlx-community/Qwen3-235B-A22B-Thinking-2507-4bit", "235B MoE", 132.3, 262144, "mlx", "Qwen 3 flagship reasoning"),
    ("Frontier (192 GB+)", "mlx-community/DeepSeek-V4-Flash-4bit", "MoE", 151.5, 1048576, "mlx", "DeepSeek V4 Flash, 1M context"),
    ("Frontier (256 GB+)", "mlx-community/GLM-4.6-4bit", "355B MoE", 198.6, 202752, "mlx", "Zhipu GLM 4.6 flagship"),
    ("Frontier (256 GB+)", "mlx-community/Qwen3.5-397B-A17B-4bit", "397B MoE", 223.9, 262144, "mlx", "Qwen 3.5 flagship"),
    ("Frontier (256 GB+)", "mlx-community/Llama-4-Maverick-17B-128E-Instruct-4bit", "400B MoE", 225.9, 1048576, "mlx", "Meta Llama 4 Maverick"),
    ("Frontier (512 GB)", "mlx-community/Qwen3-Coder-480B-A35B-Instruct-4bit", "480B MoE", 270.1, 262144, "mlx", "Qwen's largest coding model"),
    ("Frontier (512 GB)", "mlx-community/DeepSeek-R1-0528-4bit", "671B MoE", 377.6, 163840, "mlx", "Full DeepSeek R1, top open reasoning"),
    ("Frontier (512 GB)", "mlx-community/DeepSeek-V3.1-4bit", "671B MoE", 377.6, 163840, "mlx", "Full DeepSeek V3.1"),
    # AirLLM: full-precision models streamed from disk. Prompt is capped at 512 tokens.
    ("AirLLM", "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "1.1B", 2.20, 2048, "airllm", "Layer-streaming demo (512-token prompt cap)"),
    ("AirLLM", "garage-bAInd/Platypus2-7B", "7B", 13.5, 4096, "airllm", "Slow disk streaming (512-token prompt cap)"),
]


# --------------------------------------------------------------------------------------
# Model discovery
# --------------------------------------------------------------------------------------

def dir_size(path: Path) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def read_config(path: Path) -> dict | None:
    try:
        return json.loads((path / "config.json").read_text())
    except Exception:
        return None


def describe_model(path: Path, repo_id: str, source: str) -> dict | None:
    cfg = read_config(path)
    if cfg is None:
        return None
    if not (any(path.glob("*.safetensors")) or any(path.glob("*.bin"))):
        return None
    arch = (cfg.get("architectures") or [""])[0]
    model_type = cfg.get("model_type", "")
    quantized = "quantization" in cfg or "quantization_config" in cfg
    engines = ["mlx"]
    # AirLLM's Mac path only handles unquantized Llama-style checkpoints.
    if not quantized and model_type in ("llama", "mistral"):
        engines.append("airllm")
    text_cfg = cfg.get("text_config") or {}
    return {
        "id": str(path),
        "name": repo_id.split("/")[-1],
        "repo_id": repo_id,
        "path": str(path),
        "source": source,
        "architecture": arch,
        "model_type": model_type,
        "quantized": quantized,
        "engines": engines,
        "size_bytes": dir_size(path),
        "context": int(cfg.get("max_position_embeddings") or text_cfg.get("max_position_embeddings") or 0),
    }


def folder_dirname(repo_id: str) -> str:
    return repo_id.replace("/", "__")


def scan_folder(folder: Path) -> list[dict]:
    out = []
    if not folder.is_dir():
        return out
    for child in sorted(folder.iterdir()):
        if not child.is_dir() or child.name.startswith("."):
            continue
        # Skip folders that are still downloading.
        if any(j["path"] == str(child) and j["status"] in ("starting", "downloading") for j in downloads.values()):
            continue
        m = describe_model(child, child.name.replace("__", "/"), "folder")
        if m:
            out.append(m)
    return out


def scan_hf_cache() -> list[dict]:
    out = []
    if not HF_CACHE.is_dir():
        return out
    for repo_dir in sorted(HF_CACHE.glob("models--*")):
        repo_id = repo_dir.name[len("models--"):].replace("--", "/")
        snaps = sorted((repo_dir / "snapshots").glob("*"), key=lambda p: p.stat().st_mtime, reverse=True)
        for snap in snaps:
            m = describe_model(snap, repo_id, "hf-cache")
            if m:
                m["size_bytes"] = dir_size(repo_dir / "blobs")  # snapshots are symlinks into blobs
                out.append(m)
                break
    return out


# --------------------------------------------------------------------------------------
# Downloads
# --------------------------------------------------------------------------------------

downloads: dict[str, dict] = {}
downloads_lock = threading.Lock()


def run_download(job_id: str, repo_id: str, target: Path):
    from huggingface_hub import HfApi, snapshot_download

    job = downloads[job_id]
    try:
        info = HfApi().model_info(repo_id, files_metadata=True)
        names = [s.rfilename for s in info.siblings]
        ignore = ["*.gguf", "*.onnx", "*.msgpack", "*.h5", "*.ot", "original/*", "onnx/*"]
        if any(n.endswith(".safetensors") for n in names):
            ignore += ["*.bin", "*.pt", "*.pth"]  # skip duplicate PyTorch weights
        wanted = [s for s in info.siblings if not any(fnmatch.fnmatch(s.rfilename, p) for p in ignore)]
        job["total"] = sum((s.size or 0) for s in wanted)
        job["status"] = "downloading"

        stop = threading.Event()

        def progress():
            while not stop.is_set():
                if target.exists():
                    job["downloaded"] = min(dir_size(target), job["total"] or 1 << 62)
                stop.wait(1.0)

        t = threading.Thread(target=progress, daemon=True)
        t.start()
        try:
            snapshot_download(repo_id, local_dir=str(target), ignore_patterns=ignore)
        finally:
            stop.set()
            t.join()
        shutil.rmtree(target / ".cache", ignore_errors=True)
        job["downloaded"] = dir_size(target)
        job["status"] = "done"
    except Exception as e:
        job["status"] = "error"
        job["error"] = f"{type(e).__name__}: {e}"


# --------------------------------------------------------------------------------------
# Inference worker
# --------------------------------------------------------------------------------------

THINK_RE = re.compile(r"<think>.*?</think>", re.S)


class Worker:
    """Owns the loaded model and runs every MLX/AirLLM call on a single thread."""

    def __init__(self):
        self.jobs: queue.Queue = queue.Queue()
        self.loaded_key = None  # (engine, path)
        self.model = None
        self.tokenizer = None
        self.cancel = threading.Event()
        self.busy = False
        self.tokenizers: dict[str, object] = {}
        threading.Thread(target=self.loop, daemon=True).start()

    def submit(self, fn, *args) -> queue.Queue:
        out: queue.Queue = queue.Queue()
        self.jobs.put((fn, args, out))
        return out

    def loop(self):
        while True:
            fn, args, out = self.jobs.get()
            self.busy = True
            try:
                fn(out, *args)
            except Exception as e:
                out.put({"type": "error", "message": friendly_error(e)})
            finally:
                self.busy = False
                out.put(None)

    # ---- model lifecycle -------------------------------------------------------------

    def unload(self, out=None):
        self.model = None
        self.tokenizer = None
        self.loaded_key = None
        gc.collect()
        try:
            import mlx.core as mx
            mx.clear_cache()
        except Exception:
            pass
        if out is not None:
            out.put({"type": "unloaded"})

    def ensure_loaded(self, out, engine: str, path: str, name: str = ""):
        key = (engine, path)
        if self.loaded_key == key:
            return
        self.unload()
        label = name or Path(path).name
        out.put({"type": "status", "message": f"Loading {label}..."})
        t0 = time.time()
        if engine == "mlx":
            from mlx_lm import load
            self.model, self.tokenizer = load(path)
        elif engine == "airllm":
            from airllm import AutoModel
            out.put({"type": "status", "message": "AirLLM: preparing layer shards (first run can take minutes)..."})
            self.model = AutoModel.from_pretrained(path)
            self.tokenizer = self.model.tokenizer
        else:
            raise ValueError(f"Unknown engine {engine}")
        self.loaded_key = key
        out.put({"type": "loaded", "seconds": round(time.time() - t0, 2)})

    # ---- prompting -------------------------------------------------------------------

    def build_prompt(self, messages: list[dict], thinking: bool = True) -> str:
        tok = self.tokenizer
        if getattr(tok, "chat_template", None):
            try:
                if not thinking:
                    return tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False,
                                                   enable_thinking=False)
                return tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
            except Exception:
                try:
                    return tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
                except Exception:
                    pass
        parts = [f"{m['role'].capitalize()}: {m['content']}" for m in messages]
        parts.append("Assistant:")
        return "\n\n".join(parts)

    # ---- generation ------------------------------------------------------------------

    def generate(self, out, req: "ChatRequest"):
        self.cancel.clear()
        self.ensure_loaded(out, req.engine, req.model_path, req.model_name)
        messages = [m.model_dump() for m in req.messages]
        if req.system_prompt.strip():
            messages = [{"role": "system", "content": req.system_prompt.strip()}] + messages
        prompt = self.build_prompt(messages, thinking=req.thinking)
        emit = lambda t: out.put({"type": "token", "text": t})
        if prompt.rstrip().endswith("<think>"):
            # Templates such as Qwen 3.5 open the reasoning block in the prompt itself, so the
            # model only ever emits the closing tag. Emit the opening tag so clients can fold it.
            emit("<think>\n")
        if req.engine == "mlx":
            _, stats = self._generate_mlx(req, prompt, emit)
        else:
            _, stats = self._generate_airllm(req, prompt, emit)
        out.put({"type": "done", "stats": stats})

    def _generate_mlx(self, req, prompt, emit):
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler

        sampler = make_sampler(temp=req.temperature, top_p=req.top_p if req.top_p < 1.0 else 0.0)
        kwargs = {}
        if req.kv_bits in (4, 8):
            kwargs["kv_bits"] = req.kv_bits
        elif req.context_limit > 0:
            # mlx-lm cannot quantize a rotating cache, so the window only applies without kv_bits.
            kwargs["max_kv_size"] = req.context_limit
        t0 = time.time()
        first = None
        last = None
        text = ""
        for r in stream_generate(self.model, self.tokenizer, prompt, max_tokens=req.max_tokens,
                                 sampler=sampler, **kwargs):
            if first is None:
                first = time.time()
            if r.text:
                text += r.text
                emit(r.text)
            last = r
            if self.cancel.is_set():
                break
        end = time.time()
        return text, {
            "engine": "mlx",
            "prompt_tokens": last.prompt_tokens if last else 0,
            "generation_tokens": last.generation_tokens if last else 0,
            "tokens_per_second": round(last.generation_tps, 2) if last else 0,
            "prompt_tokens_per_second": round(last.prompt_tps, 2) if last else 0,
            "time_to_first_token": round((first or end) - t0, 3),
            "total_seconds": round(end - t0, 2),
            "peak_memory_gb": round(last.peak_memory, 2) if last else 0,
            "finish_reason": "cancelled" if self.cancel.is_set() else (last.finish_reason if last else None),
        }

    def _generate_airllm(self, req, prompt, emit):
        import mlx.core as mx

        tok = self.tokenizer
        ids = tok(prompt, return_tensors="np", return_attention_mask=False, truncation=True,
                  max_length=512, padding=False)["input_ids"]
        eos = tok.eos_token_id
        tokens: list[int] = []
        emitted = ""
        t0 = time.time()
        first = None
        finish = "length"
        for t in self.model.model_generate(mx.array(ids), temperature=req.temperature):
            tid = int(t.item())
            if first is None:
                first = time.time()
            if tid == eos:
                finish = "stop"
                break
            tokens.append(tid)
            text = tok.decode(tokens, skip_special_tokens=True)
            if len(text) > len(emitted):
                emit(text[len(emitted):])
                emitted = text
            if len(tokens) >= req.max_tokens:
                break
            if self.cancel.is_set():
                finish = "cancelled"
                break
        end = time.time()
        gen_time = max(end - (first or end), 1e-6)
        return emitted, {
            "engine": "airllm",
            "prompt_tokens": int(ids.shape[1]),
            "generation_tokens": len(tokens),
            "tokens_per_second": round(len(tokens) / gen_time, 2) if tokens else 0,
            "prompt_tokens_per_second": 0,
            "time_to_first_token": round((first or end) - t0, 3),
            "total_seconds": round(end - t0, 2),
            "peak_memory_gb": round(psutil.Process().memory_info().rss / 1e9, 2),
            "finish_reason": finish,
        }

    # ---- judging ---------------------------------------------------------------------

    def judge(self, out, req: "JudgeRequest"):
        self.cancel.clear()
        self.ensure_loaded(out, req.engine, req.judge_path, req.judge_name)
        results = []
        for i, a in enumerate(req.answers):
            if self.cancel.is_set():
                break
            out.put({"type": "status", "message": f"Judging answer {i + 1} of {len(req.answers)}..."})
            answer = THINK_RE.sub("", a.text).strip()[:6000]
            messages = [
                {"role": "system", "content": JUDGE_SYSTEM},
                {"role": "user", "content": JUDGE_TEMPLATE.format(prompt=req.prompt[:4000], answer=answer or "(empty)")},
            ]
            # The prompt makes the judge reason through a reference answer, so built-in thinking is off:
            # long-thinking models (Qwen 3.5) otherwise exhaust the budget before writing the verdict.
            prompt = self.build_prompt(messages, thinking=False)
            jr = ChatRequest(model_path=req.judge_path, engine=req.engine, messages=[], temperature=0.0,
                             max_tokens=1200)
            if req.engine == "mlx":
                text, _ = self._generate_mlx(jr, prompt, lambda t: None)
            else:
                text, _ = self._generate_airllm(jr, prompt, lambda t: None)
            score = parse_judgement(text)
            score["id"] = a.id
            results.append(score)
            out.put({"type": "score", "score": score})
        out.put({"type": "done", "scores": results})

    # ---- benchmarks ------------------------------------------------------------------

    def evaluate(self, out, req: "EvalRequest"):
        import random

        self.cancel.clear()
        self.ensure_loaded(out, req.engine, req.model_path, req.model_name)
        base = ChatRequest(model_path=req.model_path, engine=req.engine, messages=[], temperature=0.0,
                           max_tokens=req.max_tokens, kv_bits=req.kv_bits)
        gen = self._generate_mlx if req.engine == "mlx" else self._generate_airllm

        def ask(content: str) -> tuple[str, dict]:
            prompt = self.build_prompt([{"role": "user", "content": content}], thinking=req.thinking)
            text, stats = gen(base, prompt, lambda t: None)
            return THINK_RE.sub("", text).split("</think>")[-1].strip(), stats

        if "quick" in req.suites:
            for i, (qid, cat, prompt, expected, checker) in enumerate(QUICK_EVAL):
                if self.cancel.is_set():
                    break
                out.put({"type": "status", "message": f"Quiz {i + 1}/{len(QUICK_EVAL)}: {cat}"})
                answer, st = ask(prompt)
                out.put({"type": "result", "result": {
                    "suite": "quick", "id": qid, "category": cat, "label": prompt, "expected": expected,
                    "output": answer[:400], "passed": bool(checker(answer)), "context_tokens": st["prompt_tokens"],
                    "depth": 0, "tokens_per_second": st["tokens_per_second"],
                    "prompt_tokens_per_second": st["prompt_tokens_per_second"],
                    "seconds": st["total_seconds"], "peak_memory_gb": st["peak_memory_gb"]}})

        if "needle" in req.suites:
            limit = req.model_context or 1 << 30
            lengths = [n for n in req.needle_lengths if n <= limit * 0.95]
            rng = random.Random(7)
            total = len(lengths) * len(req.needle_depths)
            k = 0
            for n in lengths:
                for depth in req.needle_depths:
                    if self.cancel.is_set():
                        break
                    k += 1
                    code = f"{rng.choice(['amber', 'cobalt', 'jasper', 'saffron', 'violet'])}-{rng.randint(1000, 9999)}"
                    needle = f"Important: the secret vault passphrase is {code}."
                    hay = build_haystack(self.tokenizer, n, depth, needle)
                    question = (f"{hay}\n\nBased only on the document above, what is the secret vault passphrase? "
                                "Reply with just the passphrase.")
                    out.put({"type": "status", "message": f"Context test {k}/{total}: {formatk(n)} tokens, needle at {int(depth * 100)}%"})
                    try:
                        answer, st = ask(question)
                        passed = code.lower() in answer.lower()
                        err = None
                    except Exception as e:
                        answer, st, passed, err = "", None, False, friendly_error(e)
                    out.put({"type": "result", "result": {
                        "suite": "needle", "id": f"needle-{n}-{depth}", "category": "Context",
                        "label": f"{formatk(n)} tokens, depth {int(depth * 100)}%", "expected": code,
                        "output": (err or answer)[:200], "passed": passed,
                        "context_tokens": st["prompt_tokens"] if st else n, "depth": depth,
                        "tokens_per_second": st["tokens_per_second"] if st else 0,
                        "prompt_tokens_per_second": st["prompt_tokens_per_second"] if st else 0,
                        "seconds": st["total_seconds"] if st else 0,
                        "peak_memory_gb": st["peak_memory_gb"] if st else 0}})
                    if err:
                        break  # larger contexts will fail too (usually out of memory)
        out.put({"type": "done"})

    # ---- tokenizers ------------------------------------------------------------------

    def count_tokens(self, path: str, text: str) -> int:
        tok = self.tokenizers.get(path)
        if tok is None:
            from transformers import AutoTokenizer
            tok = AutoTokenizer.from_pretrained(path, trust_remote_code=True)
            self.tokenizers[path] = tok
        return len(tok.encode(text, add_special_tokens=False))


JUDGE_SYSTEM = (
    "You are a strict, fair evaluator of AI assistant answers. You grade one answer at a time "
    "and reply with JSON only."
)

JUDGE_TEMPLATE = """Grade the answer to the user's prompt.

<prompt>
{prompt}
</prompt>

<answer>
{answer}
</answer>

Work in this order:
1. Write your own short, correct answer to the prompt ("reference").
2. Compare the answer above with your reference and list any factual or logical errors ("errors").
3. Score each criterion from 1 (very poor) to 10 (excellent). Any factual error must cap accuracy and overall at 3.
   - accuracy: is it factually and logically correct?
   - helpfulness: does it fully address what was asked?
   - clarity: is it well organized and easy to read?

Reply with exactly one JSON object and nothing else:
{{"reference": "<your answer>", "errors": "<errors found, or none>", "accuracy": <1-10>, "helpfulness": <1-10>, "clarity": <1-10>, "overall": <1-10>, "verdict": "<one short sentence>"}}"""


def parse_judgement(text: str) -> dict:
    text = THINK_RE.sub("", text).split("</think>")[-1]  # some templates open <think> in the prompt
    result = {"accuracy": 0.0, "helpfulness": 0.0, "clarity": 0.0, "overall": 0.0, "verdict": "",
              "raw": text.strip()[:600]}
    m = re.search(r"\{.*\}", text, re.S)
    data = None
    if m:
        try:
            data = json.loads(m.group(0))
        except Exception:
            data = None
    for key in ("accuracy", "helpfulness", "clarity", "overall"):
        val = None
        if isinstance(data, dict) and key in data:
            val = data[key]
        else:
            km = re.search(rf'"?{key}"?\s*[:=]\s*(\d+(?:\.\d+)?)', text, re.I)
            if km:
                val = km.group(1)
        try:
            result[key] = max(0.0, min(10.0, float(val))) if val is not None else 0.0
        except (TypeError, ValueError):
            result[key] = 0.0
    if not result["overall"]:
        parts = [result[k] for k in ("accuracy", "helpfulness", "clarity") if result[k]]
        result["overall"] = round(sum(parts) / len(parts), 1) if parts else 0.0
    if isinstance(data, dict):
        for k in ("verdict", "errors", "reference"):
            if isinstance(data.get(k), str):
                result[k] = data[k].strip()
    result["parsed"] = bool(result["overall"])
    return result


# --------------------------------------------------------------------------------------
# Benchmarks
# --------------------------------------------------------------------------------------

def _is_json_ada(text: str) -> bool:
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return False
    try:
        d = json.loads(m.group(0))
    except Exception:
        return False
    return d.get("name") == "Ada" and d.get("age") in (36, 36.0)


def _three_lower_words(text: str) -> bool:
    t = text.strip().strip('"').strip()
    return len(t.split()) == 3 and t == t.lower() and re.fullmatch(r"[a-z]+( [a-z]+){2}", t) is not None


QUICK_EVAL = [
    # id, category, prompt, expected (shown to the user), checker
    ("arith", "Math", "What is 17 * 23? Reply with just the number.", "391",
     lambda t: re.search(r"\b391\b", t) is not None),
    ("time", "Math", "A train leaves at 3:15 PM and arrives at 5:45 PM. How many minutes is the trip? Reply with just the number.", "150",
     lambda t: re.search(r"\b150\b", t) is not None),
    ("percent", "Math", "A shirt costs $80 and is discounted by 25%. What is the new price in dollars? Reply with just the number.", "60",
     lambda t: re.search(r"\b60(\.0+)?\b", t) is not None),
    ("logic", "Reasoning", "All bloops are razzies and all razzies are lazzies. Are all bloops definitely lazzies? Answer yes or no.", "yes",
     lambda t: re.search(r"\byes\b", t, re.I) is not None and re.search(r"\bno\b", t, re.I) is None),
    ("siblings", "Reasoning", "Sally has 3 brothers. Each of her brothers has 2 sisters. How many sisters does Sally have? Reply with just the number.", "1",
     lambda t: re.search(r"\b(1|one)\b", t, re.I) is not None and re.search(r"\b(2|two)\b", t, re.I) is None),
    ("order", "Reasoning", "Tom is taller than Ann. Ann is taller than Joe. Who is the shortest? Reply with just the name.", "Joe",
     lambda t: "joe" in t.lower() and "ann" not in t.lower()),
    ("gold", "Knowledge", "What is the chemical symbol for gold? Reply with just the symbol.", "Au",
     lambda t: re.search(r"\bAu\b", t) is not None),
    ("capital", "Knowledge", "What is the capital of Australia? Reply with just the city name.", "Canberra",
     lambda t: "canberra" in t.lower()),
    ("code", "Coding", "What does this Python code print? print(sorted([3, 1, 2])[::-1]) Reply with just the output.", "[3, 2, 1]",
     lambda t: re.search(r"\[\s*3\s*,\s*2\s*,\s*1\s*\]", t) is not None),
    ("code2", "Coding", "In Python, what is len('hello world')? Reply with just the number.", "11",
     lambda t: re.search(r"\b11\b", t) is not None),
    ("json", "Instructions", "Return a JSON object with key name set to the string Ada and key age set to the number 36. Output only the JSON.", '{"name": "Ada", "age": 36}',
     _is_json_ada),
    ("words", "Instructions", "Reply with exactly three words, all lowercase, with no punctuation.", "three lowercase words",
     _three_lower_words),
    ("spanish", "Language", "Translate 'good morning' into Spanish. Reply with just the translation.", "buenos días",
     lambda t: re.search(r"buen[oa]s\s+d[ií]as", t, re.I) is not None),
]

FILLER = [
    "The committee reviewed the quarterly logistics report and noted steady improvements in warehouse throughput.",
    "Rainfall in the northern valley was slightly above average, which helped the orchards recover after a dry spring.",
    "Several engineers proposed refactoring the billing service to reduce latency during peak traffic hours.",
    "The museum extended its opening hours for the summer exhibition on early maritime navigation instruments.",
    "A local bakery started offering sourdough workshops on weekends, and the first sessions sold out quickly.",
    "Researchers measured soil acidity at forty sites and found the eastern plots were consistently more alkaline.",
    "The city council approved new bike lanes along the river, connecting the university with the old market.",
    "Customer support tickets dropped after the onboarding guide was rewritten with clearer screenshots.",
    "The orchestra rehearsed the second movement three times before the conductor was satisfied with the tempo.",
    "Shipping delays eased in the autumn as two new container cranes came online at the southern port.",
    "A volunteer group cataloged the library's rare maps and digitized more than two hundred of them.",
    "The hiking club mapped a new trail that climbs gently through pine forest to a quiet alpine lake.",
]


def build_haystack(tok, target_tokens: int, depth: float, needle: str) -> str:
    """Filler text of roughly target_tokens tokens with the needle sentence inserted at the given depth."""
    per = max(1, len(tok.encode(" ".join(FILLER), add_special_tokens=False)) // len(FILLER))
    n = max(4, target_tokens // per)
    sentences = [FILLER[(i * 7 + i // len(FILLER)) % len(FILLER)] for i in range(n)]
    sentences.insert(int(len(sentences) * depth), needle)
    return " ".join(sentences)


def friendly_error(e: Exception) -> str:
    msg = f"{type(e).__name__}: {e}"
    low = msg.lower()
    if "out of memory" in low or "insufficient memory" in low or ("metal" in low and "memory" in low):
        return "Not enough memory to run this model. Try a smaller or more heavily quantized model, or close other apps."
    if "model type" in low and "not supported" in low:
        return f"This architecture isn't supported by the installed mlx-lm. ({msg})"
    return msg


def formatk(n: int) -> str:
    return f"{n // 1000}K" if n >= 1000 else str(n)


worker = Worker()


# --------------------------------------------------------------------------------------
# HTTP API
# --------------------------------------------------------------------------------------

app = FastAPI(title="Model Playground backend", version=VERSION)


class Message(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    model_path: str
    model_name: str = ""
    engine: str = "mlx"
    messages: list[Message]
    system_prompt: str = ""
    temperature: float = 0.7
    top_p: float = 1.0
    max_tokens: int = 512
    context_limit: int = 0  # 0 = unlimited; otherwise a sliding KV-cache window in tokens
    kv_bits: int = 0        # 0 = full precision KV cache; 8 or 4 quantize it to save memory
    thinking: bool = True   # let hybrid reasoning models (Qwen 3) think before answering


class JudgeAnswer(BaseModel):
    id: str
    text: str


class JudgeRequest(BaseModel):
    judge_path: str
    judge_name: str = ""
    engine: str = "mlx"
    prompt: str
    answers: list[JudgeAnswer]


class EvalRequest(BaseModel):
    model_path: str
    model_name: str = ""
    engine: str = "mlx"
    suites: list[str] = ["quick"]
    needle_lengths: list[int] = [1000, 4000, 8000, 16000]
    needle_depths: list[float] = [0.1, 0.5, 0.9]
    model_context: int = 0
    max_tokens: int = 256
    kv_bits: int = 0
    thinking: bool = False


class TokenizeRequest(BaseModel):
    paths: list[str]
    text: str


class DownloadRequest(BaseModel):
    repo_id: str
    folder: str


def stream_job(out: queue.Queue):
    finished = False
    try:
        while True:
            ev = out.get()
            if ev is None:
                finished = True
                break
            yield json.dumps(ev) + "\n"
    finally:
        if not finished:
            # The client went away mid-generation: stop the worker so it is free for the next request.
            worker.cancel.set()


@app.get("/health")
def health():
    return {"ok": True, "app": APP_ID, "version": VERSION, "busy": worker.busy,
            "loaded": list(worker.loaded_key) if worker.loaded_key else None}


@app.get("/system")
def system(folder: str = ""):
    vm = psutil.virtual_memory()
    disk_path = folder if folder and os.path.isdir(folder) else str(Path.home())
    du = shutil.disk_usage(disk_path)
    return {
        "total_ram_gb": round(vm.total / 1e9, 1),
        "available_ram_gb": round(vm.available / 1e9, 1),
        "free_disk_gb": round(du.free / 1e9, 1),
    }


@app.get("/catalog")
def catalog():
    return [
        {"family": f, "repo_id": r, "params": p, "size_gb": s, "context": c, "engine": e, "notes": n}
        for f, r, p, s, c, e, n in CATALOG
    ]


@app.get("/models")
def models(folder: str = "", include_hf_cache: bool = True):
    found = []
    if folder:
        found += scan_folder(Path(folder).expanduser())
    if include_hf_cache:
        seen = {m["repo_id"] for m in found}
        found += [m for m in scan_hf_cache() if m["repo_id"] not in seen]
    return found


@app.get("/search")
def search(q: str = "", mlx_only: bool = True, limit: int = 50):
    from huggingface_hub import HfApi

    kwargs = dict(search=q or None, sort="downloads", limit=limit, pipeline_tag="text-generation")
    if mlx_only:
        kwargs["author"] = "mlx-community"
    try:
        return [
            {"repo_id": m.id, "downloads": m.downloads or 0, "likes": m.likes or 0, "tags": []}
            for m in HfApi().list_models(**kwargs)
        ]
    except Exception as e:
        raise HTTPException(502, f"Hugging Face search failed: {e}")


@app.post("/download")
def download(req: DownloadRequest):
    folder = Path(req.folder).expanduser()
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / folder_dirname(req.repo_id)
    with downloads_lock:
        for jid, j in downloads.items():
            if j["repo_id"] == req.repo_id and j["status"] in ("starting", "downloading"):
                return {"job_id": jid}
        jid = uuid.uuid4().hex[:8]
        downloads[jid] = {"job_id": jid, "repo_id": req.repo_id, "path": str(target), "status": "starting",
                          "downloaded": 0, "total": 0, "error": None}
    threading.Thread(target=run_download, args=(jid, req.repo_id, target), daemon=True).start()
    return {"job_id": jid}


@app.get("/downloads")
def list_downloads():
    return list(downloads.values())


@app.post("/chat")
def chat(req: ChatRequest):
    if not os.path.isdir(req.model_path):
        raise HTTPException(404, f"Model folder not found: {req.model_path}")
    return StreamingResponse(stream_job(worker.submit(worker.generate, req)), media_type="application/x-ndjson")


@app.post("/judge")
def judge(req: JudgeRequest):
    if not os.path.isdir(req.judge_path):
        raise HTTPException(404, f"Judge model folder not found: {req.judge_path}")
    return StreamingResponse(stream_job(worker.submit(worker.judge, req)), media_type="application/x-ndjson")


@app.post("/eval")
def evaluate(req: EvalRequest):
    if not os.path.isdir(req.model_path):
        raise HTTPException(404, f"Model folder not found: {req.model_path}")
    return StreamingResponse(stream_job(worker.submit(worker.evaluate, req)), media_type="application/x-ndjson")


@app.get("/eval/suites")
def eval_suites():
    return {"quick": [{"id": q[0], "category": q[1], "prompt": q[2], "expected": q[3]} for q in QUICK_EVAL]}


@app.post("/tokenize")
def tokenize(req: TokenizeRequest):
    counts = {}
    for p in req.paths:
        try:
            counts[p] = worker.count_tokens(p, req.text)
        except Exception:
            counts[p] = None
    return {"counts": counts, "characters": len(req.text), "words": len(req.text.split())}


@app.post("/stop")
def stop():
    worker.cancel.set()
    return {"ok": True}


@app.post("/unload")
def unload():
    q = worker.submit(lambda out: worker.unload(out))
    while q.get() is not None:
        pass
    return {"ok": True}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")
