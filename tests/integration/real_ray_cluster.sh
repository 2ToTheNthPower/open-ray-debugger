#!/usr/bin/env bash
# End-to-end tests against a real Ray cluster.
#
#   tests/integration/real_ray_cluster.sh [scenario...]
#
# Scenarios: breakpoint actor post-mortem job (default: all).
#
# Requires `ray[default]` and `debugpy` importable by $PYTHON and a nvim-dap
# checkout in NVIM_DAP_PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NVIM="${NVIM:-nvim}"
RAY_BIN="${RAY_BIN:-ray}"
PYTHON="${PYTHON:-python3}"
DASHBOARD_URL="${RAY_DEBUGGER_DASHBOARD_URL:-http://127.0.0.1:8265}"
export NVIM_DAP_PATH="${NVIM_DAP_PATH:?set NVIM_DAP_PATH to a nvim-dap checkout}"
export RAY_DEBUGGER_DASHBOARD_URL="$DASHBOARD_URL"

if [ "$#" -gt 0 ]; then
  SCENARIOS=("$@")
else
  SCENARIOS=(breakpoint actor post-mortem job)
fi

LOG_DIR="$(mktemp -d -t ray-debugger-e2e.XXXXXX)"

cleanup() {
  "$RAY_BIN" stop --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

paused_workers() {
  curl -s "$DASHBOARD_URL/api/v0/workers?detail=1&limit=10000" |
    "$PYTHON" -c 'import json,sys; rows=json.load(sys.stdin)["data"]["result"]["result"]; print(sum(1 for w in rows if (w.get("num_paused_threads") or 0) > 0))' 2>/dev/null ||
    echo 0
}

wait_for_paused_worker() {
  for _ in $(seq 1 90); do
    if [ "$(paused_workers)" -ge 1 ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

job_logs() {
  curl -s "$DASHBOARD_URL/api/jobs/$1/logs" |
    "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("logs", ""))' 2>/dev/null || true
}

echo "==> starting a Ray head node"
"$RAY_BIN" stop --force >/dev/null 2>&1 || true
"$RAY_BIN" start --head --num-cpus=2 --disable-usage-stats >/dev/null

failures=0
for scenario in "${SCENARIOS[@]}"; do
  echo "==> scenario: $scenario"
  log="$LOG_DIR/$scenario.log"
  job_id=""
  driver_pid=""
  env_local_root=""

  case "$scenario" in
    breakpoint) expected="RESULT=441" ;;
    actor) expected="RESULT=21" ;;
    post-mortem) expected="RESULT=raised" ;;
    job) expected="RESULT=42" ;;
    *)
      echo "unknown scenario $scenario" >&2
      exit 2
      ;;
  esac

  if [ "$scenario" = "job" ]; then
    # Ray Jobs run the entrypoint from an unpacked copy of the working_dir,
    # so every frame points at /tmp/ray/.../_ray_pkg_<hash>/...
    env_local_root="$ROOT/tests/integration/workdir_app"
    job_id="$(
      RAY_ADDRESS="$DASHBOARD_URL" "$RAY_BIN" job submit --no-wait \
        --working-dir "$env_local_root" -- "$PYTHON" job_entry.py 2>&1 |
        grep -o "raysubmit_[A-Za-z0-9]*" | head -1
    )"
  else
    "$PYTHON" "$ROOT/tests/integration/ray_driver.py" "$scenario" >"$log" 2>&1 &
    driver_pid=$!
  fi

  if ! wait_for_paused_worker; then
    echo "FAILED [$scenario]: no worker paused" >&2
    [ -n "$job_id" ] && job_logs "$job_id" >"$log"
    cat "$log" >&2
    failures=$((failures + 1))
    continue
  fi

  if ! RAY_DEBUGGER_SCENARIO="$scenario" RAY_DEBUGGER_LOCAL_ROOT="$env_local_root" \
    "$NVIM" --clean -l "$ROOT/tests/integration/attach_ray_task.lua"; then
    failures=$((failures + 1))
    continue
  fi

  finished=0
  for _ in $(seq 1 60); do
    [ -n "$job_id" ] && job_logs "$job_id" >"$log"
    if grep -q "$expected" "$log" 2>/dev/null; then
      finished=1
      break
    fi
    sleep 1
  done
  if [ "$finished" = 1 ]; then
    echo "PASSED [$scenario]"
  else
    echo "FAILED [$scenario]: task did not finish with $expected; log:" >&2
    cat "$log" >&2
    failures=$((failures + 1))
  fi
  [ -n "$driver_pid" ] && wait "$driver_pid" 2>/dev/null || true
done

if [ "$failures" -gt 0 ]; then
  echo "$failures scenario(s) failed (logs in $LOG_DIR)" >&2
  exit 1
fi
echo "PASSED: all real Ray cluster scenarios (${SCENARIOS[*]})"
