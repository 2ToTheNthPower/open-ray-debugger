#!/usr/bin/env bash
# End-to-end test against a real Ray cluster.
#
# Requires `ray[default]` and `debugpy` to be importable by `python3`
# (see `make test-ray`), plus a nvim-dap checkout in NVIM_DAP_PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NVIM="${NVIM:-nvim}"
RAY_BIN="${RAY_BIN:-ray}"
PYTHON="${PYTHON:-python3}"
DASHBOARD_URL="${RAY_DEBUGGER_DASHBOARD_URL:-http://127.0.0.1:8265}"
DRIVER_LOG="$(mktemp -t ray-debugger-driver.XXXXXX.log)"

cleanup() {
  "$RAY_BIN" stop --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> stopping any existing Ray cluster"
"$RAY_BIN" stop --force >/dev/null 2>&1 || true

echo "==> starting a Ray head node"
"$RAY_BIN" start --head --num-cpus=2 --disable-usage-stats >/dev/null

echo "==> running the Ray driver (pauses on breakpoint())"
"$PYTHON" "$ROOT/tests/integration/ray_driver.py" >"$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!

echo "==> waiting for a paused worker on $DASHBOARD_URL"
paused=0
for _ in $(seq 1 90); do
  paused="$(
    curl -s "$DASHBOARD_URL/api/v0/workers?detail=1&limit=10000" |
      "$PYTHON" -c 'import json,sys; data=json.load(sys.stdin)["data"]["result"]["result"]; print(sum(1 for w in data if (w.get("num_paused_threads") or 0) > 0))' 2>/dev/null || echo 0
  )"
  if [ "$paused" -ge 1 ]; then
    break
  fi
  sleep 1
done

if [ "$paused" -lt 1 ]; then
  echo "FAILED: no worker paused; driver log:" >&2
  cat "$DRIVER_LOG" >&2
  exit 1
fi

echo "==> attaching nvim-dap through ray-debugger.nvim"
NVIM_DAP_PATH="${NVIM_DAP_PATH:?set NVIM_DAP_PATH to a nvim-dap checkout}" \
  "$NVIM" --clean -l "$ROOT/tests/integration/attach_ray_task.lua"

echo "==> waiting for the task to finish"
for _ in $(seq 1 60); do
  if grep -q "RESULT=441" "$DRIVER_LOG" 2>/dev/null; then
    echo "PASSED: real Ray cluster end-to-end test"
    exit 0
  fi
  if ! kill -0 "$DRIVER_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "FAILED: driver did not finish; log:" >&2
cat "$DRIVER_LOG" >&2
exit 1
