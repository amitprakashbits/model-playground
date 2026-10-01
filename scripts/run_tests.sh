#!/bin/bash
# Runs both end-to-end suites: the backend API test and the in-app self-test.
# Needs Qwen3-0.6B-4bit and LFM2.5-1.2B-Instruct-4bit (downloaded automatically by the backend test).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${MP_PYTHON:-$HOME/airllm/.venv/bin/python}"

echo "== Backend end-to-end test"
"$PY" "$ROOT/tests/test_backend_e2e.py"

echo "== App self-test"
"$ROOT/build.sh"
mkdir -p "$ROOT/build/snapshots"
MP_SNAPSHOT_DIR="$ROOT/build/snapshots" "$ROOT/build/Model Playground.app/Contents/MacOS/ModelPlayground" --selftest
echo "Screenshots of every screen: $ROOT/build/snapshots"
