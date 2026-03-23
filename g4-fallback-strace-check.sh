#!/usr/bin/env bash

set -euo pipefail

# G4 probe:
# Confirm runtime fallback path usage by tracing openat/openat2 and
# verifying TensileLibrary_*_fallback.{dat,hsaco} access on gfx900/MI25.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-${1:-tinyllama:latest}}"
PROMPT="${PROMPT:-Generate a 160-word plain-text note about ROCm fallback verification on gfx900.}"
NUM_PREDICT="${NUM_PREDICT:-200}"
TEMPERATURE="${TEMPERATURE:-0.1}"

HOST="${HOST:-127.0.0.1:11534}"
BASE_URL="http://${HOST}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"

OLLAMA_BIN="${OLLAMA_BIN:-$WORKSPACE_ROOT/ollama-src/ollama}"
OLLAMA_MODELS="${OLLAMA_MODELS:-$WORKSPACE_ROOT/ollama-models}"
OLLAMA_LIBRARY_PATH="${OLLAMA_LIBRARY_PATH:-$WORKSPACE_ROOT/ollama-src/build/lib/ollama}"
ROCBLAS_TENSILE_LIBPATH="${ROCBLAS_TENSILE_LIBPATH:-$WORKSPACE_ROOT/ROCm-repos_AETS/rocBLAS/build-mi25-gfx900/release/rocblas-install/lib/rocblas/library}"

mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
STRACE_PREFIX="$LOG_DIR/g4_strace_openat_${MODEL_TAG}_${TS}.log"
SERVE_OUT="$LOG_DIR/g4_serve_stdout_${MODEL_TAG}_${TS}.log"
SERVE_ERR="$LOG_DIR/g4_serve_stderr_${MODEL_TAG}_${TS}.log"
GEN_LOG="$LOG_DIR/g4_generate_${MODEL_TAG}_${TS}.json"
SUMMARY="$LOG_DIR/g4_summary_${MODEL_TAG}_${TS}.txt"

if ! command -v strace >/dev/null 2>&1; then
  echo "ERROR: strace is required but not found" >&2
  exit 1
fi

if [[ ! -x "$OLLAMA_BIN" ]]; then
  echo "ERROR: ollama binary not executable: $OLLAMA_BIN" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${SERVE_PID:-}" ]] && kill -0 "$SERVE_PID" >/dev/null 2>&1; then
    # Kill the whole process group (strace + traced ollama serve + runner children).
    kill -TERM -- "-${SERVE_PID}" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      if ! kill -0 "$SERVE_PID" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
    kill -KILL -- "-${SERVE_PID}" >/dev/null 2>&1 || true
    wait "$SERVE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_api() {
  local i
  for i in $(seq 1 60); do
    if curl -fsS "$BASE_URL/api/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

export OLLAMA_HOST="$HOST"
export OLLAMA_MODELS
export OLLAMA_LIBRARY_PATH
export LD_LIBRARY_PATH="${OLLAMA_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
export ROCBLAS_TENSILE_LIBPATH
export HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-9.0.0}"
export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0}"

# Run probe server in a dedicated process group so cleanup is deterministic.
setsid strace -ff -s 300 -e trace=openat,openat2 -o "$STRACE_PREFIX" \
  "$OLLAMA_BIN" serve >"$SERVE_OUT" 2>"$SERVE_ERR" &
SERVE_PID=$!

if ! wait_for_api; then
  {
    echo "timestamp=$TS"
    echo "result=server_not_ready"
    echo "host=$HOST"
    echo "SERVE_ERR=$SERVE_ERR"
  } > "$SUMMARY"
  echo "summary=$SUMMARY"
  exit 2
fi

curl -s "$BASE_URL/api/generate" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"${PROMPT}\",\"stream\":false,\"options\":{\"num_predict\":${NUM_PREDICT},\"temperature\":${TEMPERATURE}}}" \
  > "$GEN_LOG"

sleep 2

cleanup

fallback_dat_count="$(rg -n "TensileLibrary_.*_fallback\\.dat" "${STRACE_PREFIX}"* | wc -l | tr -d ' ')"
fallback_hsaco_count="$(rg -n "TensileLibrary_.*_fallback_gfx900\\.hsaco" "${STRACE_PREFIX}"* | wc -l | tr -d ' ')"
hip_backend_count="$(rg -n "libggml-hip\\.so" "${STRACE_PREFIX}"* | wc -l | tr -d ' ')"

{
  echo "timestamp=$TS"
  echo "host=$HOST"
  echo "model=$MODEL"
  echo "GEN_LOG=$GEN_LOG"
  echo "STRACE_PREFIX=$STRACE_PREFIX"
  echo "SERVE_OUT=$SERVE_OUT"
  echo "SERVE_ERR=$SERVE_ERR"
  echo
  echo "--- generate result ---"
  jq -r '.model,.done,.done_reason,.total_duration,.load_duration,.prompt_eval_count,.eval_count' "$GEN_LOG" 2>/dev/null || cat "$GEN_LOG"
  echo
  echo "--- evidence counts ---"
  echo "libggml_hip_openat=${hip_backend_count}"
  echo "fallback_dat_openat=${fallback_dat_count}"
  echo "fallback_hsaco_openat=${fallback_hsaco_count}"
  echo
  echo "--- evidence sample: backend load ---"
  {
    set +o pipefail
    rg -n "libggml-hip\\.so|librocblas\\.so\\.5" "${STRACE_PREFIX}"* | head -n 20 || true
    set -o pipefail
  }
  echo
  echo "--- evidence sample: fallback .dat ---"
  {
    set +o pipefail
    rg -n "TensileLibrary_.*_fallback\\.dat" "${STRACE_PREFIX}"* | head -n 20 || true
    set -o pipefail
  }
  echo
  echo "--- evidence sample: fallback .hsaco ---"
  {
    set +o pipefail
    rg -n "TensileLibrary_.*_fallback_gfx900\\.hsaco" "${STRACE_PREFIX}"* | head -n 20 || true
    set -o pipefail
  }
} > "$SUMMARY"

echo "summary=$SUMMARY"
