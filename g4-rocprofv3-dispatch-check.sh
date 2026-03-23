#!/usr/bin/env bash

set -euo pipefail

# G4 probe (rocprofv3):
# Capture kernel/runtime traces while serving Ollama on a dedicated port,
# then run one non-stream generate request for dispatch evidence.
#
# Notes:
# - This script is for evidence collection on the canonical main-node workflow.
# - It intentionally keeps the workload short to reduce trace size.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-${1:-tinyllama:latest}}"
PROMPT="${PROMPT:-Generate a short plain-text note about rocprof dispatch tracing on gfx900.}"
NUM_PREDICT="${NUM_PREDICT:-64}"
TEMPERATURE="${TEMPERATURE:-0.1}"
NUM_CTX="${NUM_CTX:-}"
NUM_BATCH="${NUM_BATCH:-}"
NUM_THREAD="${NUM_THREAD:-}"
KEEP_ALIVE="${KEEP_ALIVE:-}"

HOST="${HOST:-127.0.0.1:11634}"
BASE_URL="http://${HOST}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
CURL_MAX_TIME="${CURL_MAX_TIME:-180}"

OLLAMA_BIN="${OLLAMA_BIN:-$WORKSPACE_ROOT/ollama-src/ollama}"
OLLAMA_MODELS="${OLLAMA_MODELS:-$WORKSPACE_ROOT/ollama-models}"
OLLAMA_LIBRARY_PATH="${OLLAMA_LIBRARY_PATH:-$WORKSPACE_ROOT/ollama-src/build-gfx900/lib/ollama}"
ROCBLAS_TENSILE_LIBPATH="${ROCBLAS_TENSILE_LIBPATH:-$WORKSPACE_ROOT/ROCm-repos_AETS/rocBLAS/build-mi25-gfx900/release/rocblas-install/lib/rocblas/library}"

mkdir -p "$LOG_DIR" "$RAW_LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
PROBE_DIR="$RAW_LOG_DIR/rocprofv3_probe_${MODEL_TAG}_${TS}"
SERVE_OUT="$RAW_LOG_DIR/rocprofv3_serve_stdout_${MODEL_TAG}_${TS}.log"
SERVE_ERR="$RAW_LOG_DIR/rocprofv3_serve_stderr_${MODEL_TAG}_${TS}.log"
GEN_LOG="$RAW_LOG_DIR/rocprofv3_generate_${MODEL_TAG}_${TS}.json"
SUMMARY="$LOG_DIR/rocprofv3_summary_${MODEL_TAG}_${TS}.txt"

mkdir -p "$PROBE_DIR"

cleanup() {
  if [[ -n "${SERVE_PGID:-}" ]] && kill -0 "$SERVE_PGID" >/dev/null 2>&1; then
    kill -TERM -- "-${SERVE_PGID}" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      if ! kill -0 "$SERVE_PGID" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
    kill -KILL -- "-${SERVE_PGID}" >/dev/null 2>&1 || true
    wait "$SERVE_PGID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_api() {
  local i
  for i in $(seq 1 60); do
    if curl -fsS --max-time 3 "$BASE_URL/api/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! command -v rocprofv3 >/dev/null 2>&1; then
  echo "ERROR: rocprofv3 not found" >&2
  exit 1
fi

if [[ ! -x "$OLLAMA_BIN" ]]; then
  echo "ERROR: ollama binary not executable: $OLLAMA_BIN" >&2
  exit 1
fi

export OLLAMA_HOST="$HOST"
export OLLAMA_MODELS
export OLLAMA_LIBRARY_PATH
export LD_LIBRARY_PATH="${OLLAMA_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
export ROCBLAS_TENSILE_LIBPATH
export HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-9.0.0}"
export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0}"

# Launch in a dedicated session; keep PGID for deterministic cleanup.
setsid bash -c \
  "exec rocprofv3 --runtime-trace --kernel-trace -f csv -d '$PROBE_DIR' -- '$OLLAMA_BIN' serve" \
  >"$SERVE_OUT" 2>"$SERVE_ERR" &
SERVE_PGID=$!

if ! wait_for_api; then
  {
    echo "timestamp=$TS"
    echo "result=server_not_ready"
    echo "host=$HOST"
    echo "PROBE_DIR=$PROBE_DIR"
    echo "SERVE_OUT=$SERVE_OUT"
    echo "SERVE_ERR=$SERVE_ERR"
  } > "$SUMMARY"
  echo "summary=$SUMMARY"
  exit 2
fi

if ! curl -sS --max-time "$CURL_MAX_TIME" "$BASE_URL/api/generate" \
  -d "$(
    jq -nc \
      --arg model "$MODEL" \
      --arg prompt "$PROMPT" \
      --arg np "$NUM_PREDICT" \
      --arg temp "$TEMPERATURE" \
      --arg num_ctx "$NUM_CTX" \
      --arg num_batch "$NUM_BATCH" \
      --arg num_thread "$NUM_THREAD" \
      --arg keep_alive "$KEEP_ALIVE" \
      '{model:$model,prompt:$prompt,stream:false}
      + (if $keep_alive != "" then {keep_alive:$keep_alive} else {} end)
      + {options:
          ({num_predict:($np|tonumber),temperature:($temp|tonumber)}
           + (if $num_ctx != "" then {num_ctx:($num_ctx|tonumber)} else {} end)
           + (if $num_batch != "" then {num_batch:($num_batch|tonumber)} else {} end)
           + (if $num_thread != "" then {num_thread:($num_thread|tonumber)} else {} end)
          )
        }'
  )" \
  > "$GEN_LOG"; then
  {
    echo "timestamp=$TS"
    echo "result=generate_failed"
    echo "host=$HOST"
    echo "PROBE_DIR=$PROBE_DIR"
    echo "GEN_LOG=$GEN_LOG"
    echo "SERVE_OUT=$SERVE_OUT"
    echo "SERVE_ERR=$SERVE_ERR"
  } > "$SUMMARY"
  echo "summary=$SUMMARY"
  exit 3
fi

sleep 2
cleanup

trace_file_count="$(find "$PROBE_DIR" -type f | wc -l | tr -d ' ')"
csv_file_count="$(find "$PROBE_DIR" -type f -name '*.csv' | wc -l | tr -d ' ')"
dispatch_rows="$(rg -n -i "KERNEL_DISPATCH|dispatch" "$PROBE_DIR" --glob '*.csv' | wc -l | tr -d ' ' || true)"
tensile_rows="$(rg -n -i "tensile|gemm|rocblas|hipblas" "$PROBE_DIR" --glob '*.csv' | wc -l | tr -d ' ' || true)"
kernel_trace_file="$(find "$PROBE_DIR" -type f -name '*kernel_trace.csv' | head -n 1 || true)"

kernel_dispatch_rows=0
kernel_mul_mat_q_rows=0
kernel_mul_mat_vec_rows=0
kernel_flash_attn_rows=0
kernel_quantize_rows=0
kernel_copy_rows=0
kernel_tensile_like_rows=0
if [[ -n "$kernel_trace_file" && -f "$kernel_trace_file" ]]; then
  {
    set +o pipefail
    kernel_dispatch_rows="$(rg -n "\"KERNEL_DISPATCH\"" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_mul_mat_q_rows="$(rg -n "mul_mat_q<" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_mul_mat_vec_rows="$(rg -n "mul_mat_vec_q<" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_flash_attn_rows="$(rg -n "flash_attn" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_quantize_rows="$(rg -n "quantize_" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_copy_rows="$(rg -n "__amd_rocclr_copyBuffer|fillBufferAligned" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_tensile_like_rows="$(rg -n -i "tensile|contraction|cijk|rocblas|gemm_ex|gemm" "$kernel_trace_file" | wc -l | tr -d ' ')"
    set -o pipefail
  }
fi

{
  echo "timestamp=$TS"
  echo "host=$HOST"
  echo "model=$MODEL"
  echo "num_predict=$NUM_PREDICT"
  echo "temperature=$TEMPERATURE"
  echo "num_ctx=$NUM_CTX"
  echo "num_batch=$NUM_BATCH"
  echo "num_thread=$NUM_THREAD"
  echo "keep_alive=$KEEP_ALIVE"
  echo "RAW_LOG_DIR=$RAW_LOG_DIR"
  echo "OLLAMA_LIBRARY_PATH=$OLLAMA_LIBRARY_PATH"
  echo "ROCBLAS_TENSILE_LIBPATH=$ROCBLAS_TENSILE_LIBPATH"
  echo "PROBE_DIR=$PROBE_DIR"
  echo "GEN_LOG=$GEN_LOG"
  echo "SERVE_OUT=$SERVE_OUT"
  echo "SERVE_ERR=$SERVE_ERR"
  echo
  echo "--- generate result ---"
  jq -r '.model,.done,.done_reason,.total_duration,.load_duration,.prompt_eval_count,.eval_count' "$GEN_LOG" 2>/dev/null || cat "$GEN_LOG"
  echo
  echo "--- rocprof output counts ---"
  echo "trace_file_count=${trace_file_count}"
  echo "csv_file_count=${csv_file_count}"
  echo "dispatch_rows=${dispatch_rows}"
  echo "tensile_or_gemm_rows=${tensile_rows}"
  if [[ -n "$kernel_trace_file" ]]; then
    echo "kernel_trace_file=${kernel_trace_file}"
    echo "kernel_dispatch_rows=${kernel_dispatch_rows}"
    echo "kernel_mul_mat_q_rows=${kernel_mul_mat_q_rows}"
    echo "kernel_mul_mat_vec_rows=${kernel_mul_mat_vec_rows}"
    echo "kernel_flash_attn_rows=${kernel_flash_attn_rows}"
    echo "kernel_quantize_rows=${kernel_quantize_rows}"
    echo "kernel_copy_rows=${kernel_copy_rows}"
    echo "kernel_tensile_like_rows=${kernel_tensile_like_rows}"
  fi
  echo
  echo "--- rocprof files ---"
  find "$PROBE_DIR" -maxdepth 4 -type f | sort
  if [[ -n "$kernel_trace_file" && -f "$kernel_trace_file" ]]; then
    echo
    echo "--- top kernel names (dispatch rows) ---"
    awk 'NR>1 && /"KERNEL_DISPATCH"/ { if (match($0, /,[0-9]+,"([^"]+)",[0-9]+,/, a)) c[a[1]]++ } END { for (k in c) print c[k] "\t" k }' "$kernel_trace_file" | sort -nr | head -n 30
  fi
  echo
  echo "--- sample matches (dispatch/tensile/gemm) ---"
  {
    set +o pipefail
    rg -n -i "KERNEL_DISPATCH|dispatch|tensile|gemm|rocblas|hipblas" "$PROBE_DIR" --glob '*.csv' | head -n 80 || true
    set -o pipefail
  }
} > "$SUMMARY"

echo "summary=$SUMMARY"
