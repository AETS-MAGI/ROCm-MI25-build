#!/usr/bin/env bash

set -euo pipefail

# G4 phase-2 orchestrator:
# Run fallback(openat/strace) and dispatch(rocprofv3) probes under the same
# model/prompt condition, then emit one consolidated link summary.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-${1:-tinyllama:latest}}"
PROMPT="${PROMPT:-Generate a concise note about fallback and kernel dispatch on gfx900.}"
NUM_PREDICT="${NUM_PREDICT:-160}"
TEMPERATURE="${TEMPERATURE:-0.1}"
NUM_CTX="${NUM_CTX:-}"
NUM_BATCH="${NUM_BATCH:-}"
NUM_THREAD="${NUM_THREAD:-}"
KEEP_ALIVE="${KEEP_ALIVE:-}"
STREAM="${STREAM:-0}"

LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
mkdir -p "$LOG_DIR"

RUN_STRACE="${RUN_STRACE:-1}"
RUN_ROCPROF="${RUN_ROCPROF:-1}"

STRACE_HOST="${STRACE_HOST:-127.0.0.1:11534}"
ROCPROF_HOST="${ROCPROF_HOST:-127.0.0.1:11634}"
ROCBLAS_LAYER="${ROCBLAS_LAYER:-9}"
ROCBLAS_VERBOSE_TENSILE_ERROR="${ROCBLAS_VERBOSE_TENSILE_ERROR:-0}"
ROCBLAS_VERBOSE_HIPBLASLT_ERROR="${ROCBLAS_VERBOSE_HIPBLASLT_ERROR:-0}"

STRACE_SUMMARY_INPUT="${STRACE_SUMMARY:-}"
ROCPROF_SUMMARY_INPUT="${ROCPROF_SUMMARY:-}"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
LINK_SUMMARY="$LOG_DIR/g4_link_summary_${MODEL_TAG}_${TS}.txt"

extract_summary_path() {
  awk -F= '/^summary=/{print $2}' | tail -n 1
}

read_kv() {
  local file="$1"
  local key="$2"
  if [[ ! -f "$file" ]]; then
    echo ""
    return 0
  fi
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file"
}

to_int_or_zero() {
  local v="${1:-}"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
  else
    echo "0"
  fi
}

run_strace_probe() {
  if [[ "$RUN_STRACE" != "1" ]]; then
    if [[ -z "$STRACE_SUMMARY_INPUT" ]]; then
      echo "ERROR: RUN_STRACE=0 requires STRACE_SUMMARY to be set" >&2
      exit 1
    fi
    echo "$STRACE_SUMMARY_INPUT"
    return 0
  fi

  local out
  out="$(
    HOST="$STRACE_HOST" \
    MODEL="$MODEL" \
    PROMPT="$PROMPT" \
    NUM_PREDICT="$NUM_PREDICT" \
    TEMPERATURE="$TEMPERATURE" \
    NUM_CTX="$NUM_CTX" \
    NUM_BATCH="$NUM_BATCH" \
    NUM_THREAD="$NUM_THREAD" \
    KEEP_ALIVE="$KEEP_ALIVE" \
    STREAM="$STREAM" \
    RAW_LOG_DIR="$RAW_LOG_DIR" \
    STRACE_TIMESTAMP=1 \
    PROBE_ROCBLAS_LOG=1 \
    ROCBLAS_LAYER="$ROCBLAS_LAYER" \
    ROCBLAS_VERBOSE_TENSILE_ERROR="$ROCBLAS_VERBOSE_TENSILE_ERROR" \
    ROCBLAS_VERBOSE_HIPBLASLT_ERROR="$ROCBLAS_VERBOSE_HIPBLASLT_ERROR" \
    "$SCRIPT_DIR/g4-fallback-strace-check.sh"
  )"

  local summary
  summary="$(printf '%s\n' "$out" | extract_summary_path)"
  if [[ -z "$summary" || ! -f "$summary" ]]; then
    echo "ERROR: failed to capture strace summary path" >&2
    printf '%s\n' "$out" >&2
    exit 2
  fi
  echo "$summary"
}

run_rocprof_probe() {
  if [[ "$RUN_ROCPROF" != "1" ]]; then
    if [[ -z "$ROCPROF_SUMMARY_INPUT" ]]; then
      echo "ERROR: RUN_ROCPROF=0 requires ROCPROF_SUMMARY to be set" >&2
      exit 1
    fi
    echo "$ROCPROF_SUMMARY_INPUT"
    return 0
  fi

  local out
  out="$(
    HOST="$ROCPROF_HOST" \
    MODEL="$MODEL" \
    PROMPT="$PROMPT" \
    NUM_PREDICT="$NUM_PREDICT" \
    TEMPERATURE="$TEMPERATURE" \
    NUM_CTX="$NUM_CTX" \
    NUM_BATCH="$NUM_BATCH" \
    NUM_THREAD="$NUM_THREAD" \
    KEEP_ALIVE="$KEEP_ALIVE" \
    STREAM="$STREAM" \
    RAW_LOG_DIR="$RAW_LOG_DIR" \
    "$SCRIPT_DIR/g4-rocprofv3-dispatch-check.sh"
  )"

  local summary
  summary="$(printf '%s\n' "$out" | extract_summary_path)"
  if [[ -z "$summary" || ! -f "$summary" ]]; then
    echo "ERROR: failed to capture rocprof summary path" >&2
    printf '%s\n' "$out" >&2
    exit 3
  fi
  echo "$summary"
}

STRACE_SUMMARY_PATH="$(run_strace_probe)"
ROCPROF_SUMMARY_PATH="$(run_rocprof_probe)"

libggml_hip_openat="$(to_int_or_zero "$(read_kv "$STRACE_SUMMARY_PATH" "libggml_hip_openat")")"
fallback_dat_openat="$(to_int_or_zero "$(read_kv "$STRACE_SUMMARY_PATH" "fallback_dat_openat")")"
fallback_hsaco_openat="$(to_int_or_zero "$(read_kv "$STRACE_SUMMARY_PATH" "fallback_hsaco_openat")")"
rocblas_trace_lines="$(to_int_or_zero "$(read_kv "$STRACE_SUMMARY_PATH" "rocblas_trace_lines")")"
rocblas_trace_handle_lines="$(to_int_or_zero "$(read_kv "$STRACE_SUMMARY_PATH" "rocblas_trace_handle_lines")")"
rocblas_trace_gemm_lines="$(to_int_or_zero "$(read_kv "$STRACE_SUMMARY_PATH" "rocblas_trace_gemm_lines")")"

kernel_dispatch_rows="$(to_int_or_zero "$(read_kv "$ROCPROF_SUMMARY_PATH" "kernel_dispatch_rows")")"
kernel_mul_mat_q_rows="$(to_int_or_zero "$(read_kv "$ROCPROF_SUMMARY_PATH" "kernel_mul_mat_q_rows")")"
kernel_mul_mat_vec_rows="$(to_int_or_zero "$(read_kv "$ROCPROF_SUMMARY_PATH" "kernel_mul_mat_vec_rows")")"
kernel_flash_attn_rows="$(to_int_or_zero "$(read_kv "$ROCPROF_SUMMARY_PATH" "kernel_flash_attn_rows")")"
kernel_quantize_rows="$(to_int_or_zero "$(read_kv "$ROCPROF_SUMMARY_PATH" "kernel_quantize_rows")")"
kernel_tensile_like_rows="$(to_int_or_zero "$(read_kv "$ROCPROF_SUMMARY_PATH" "kernel_tensile_like_rows")")"
ttft_ms_wall_strace="$(read_kv "$STRACE_SUMMARY_PATH" "ttft_ms_wall")"
stream_total_ms_wall_strace="$(read_kv "$STRACE_SUMMARY_PATH" "stream_total_ms_wall")"
ttft_ms_wall_rocprof="$(read_kv "$ROCPROF_SUMMARY_PATH" "ttft_ms_wall")"
stream_total_ms_wall_rocprof="$(read_kv "$ROCPROF_SUMMARY_PATH" "stream_total_ms_wall")"
phase_split_status_proxy="$(read_kv "$ROCPROF_SUMMARY_PATH" "phase_split_status_proxy")"
phase_split_method="$(read_kv "$ROCPROF_SUMMARY_PATH" "phase_split_method")"
prefill_kernel_tensile_like_rows="$(to_int_or_zero "$(read_kv "$ROCPROF_SUMMARY_PATH" "prefill_kernel_tensile_like_rows")")"
decode_kernel_tensile_like_rows="$(to_int_or_zero "$(read_kv "$ROCPROF_SUMMARY_PATH" "decode_kernel_tensile_like_rows")")"

fallback_confirmed=0
dispatch_confirmed=0
direct_rocblas_or_tensile_dispatch=0

if (( libggml_hip_openat > 0 && fallback_dat_openat > 0 && fallback_hsaco_openat > 0 )); then
  fallback_confirmed=1
fi

if (( kernel_dispatch_rows > 0 )); then
  dispatch_confirmed=1
fi

if (( rocblas_trace_gemm_lines > 0 || kernel_tensile_like_rows > 0 )); then
  direct_rocblas_or_tensile_dispatch=1
fi

link_status="insufficient_evidence"
if (( direct_rocblas_or_tensile_dispatch == 1 )); then
  link_status="direct_rocblas_or_tensile_dispatch_observed"
elif (( fallback_confirmed == 1 && dispatch_confirmed == 1 )); then
  link_status="indirect_link_only_same_scenario"
fi

{
  echo "timestamp=$TS"
  echo "model=$MODEL"
  echo "prompt=$PROMPT"
  echo "num_predict=$NUM_PREDICT"
  echo "temperature=$TEMPERATURE"
  echo "num_ctx=$NUM_CTX"
  echo "num_batch=$NUM_BATCH"
  echo "num_thread=$NUM_THREAD"
  echo "keep_alive=$KEEP_ALIVE"
  echo "stream=$STREAM"
  echo "raw_log_dir=$RAW_LOG_DIR"
  echo "run_strace=$RUN_STRACE"
  echo "run_rocprof=$RUN_ROCPROF"
  echo "strace_host=$STRACE_HOST"
  echo "rocprof_host=$ROCPROF_HOST"
  echo "rocblas_layer=$ROCBLAS_LAYER"
  echo "rocblas_verbose_tensile_error=$ROCBLAS_VERBOSE_TENSILE_ERROR"
  echo "rocblas_verbose_hipblaslt_error=$ROCBLAS_VERBOSE_HIPBLASLT_ERROR"
  echo "strace_summary=$STRACE_SUMMARY_PATH"
  echo "rocprof_summary=$ROCPROF_SUMMARY_PATH"
  echo
  echo "--- fallback evidence ---"
  echo "libggml_hip_openat=$libggml_hip_openat"
  echo "fallback_dat_openat=$fallback_dat_openat"
  echo "fallback_hsaco_openat=$fallback_hsaco_openat"
  echo "rocblas_trace_lines=$rocblas_trace_lines"
  echo "rocblas_trace_handle_lines=$rocblas_trace_handle_lines"
  echo "rocblas_trace_gemm_lines=$rocblas_trace_gemm_lines"
  echo
  echo "--- dispatch evidence ---"
  echo "kernel_dispatch_rows=$kernel_dispatch_rows"
  echo "kernel_mul_mat_q_rows=$kernel_mul_mat_q_rows"
  echo "kernel_mul_mat_vec_rows=$kernel_mul_mat_vec_rows"
  echo "kernel_flash_attn_rows=$kernel_flash_attn_rows"
  echo "kernel_quantize_rows=$kernel_quantize_rows"
  echo "kernel_tensile_like_rows=$kernel_tensile_like_rows"
  echo "ttft_ms_wall_strace=$ttft_ms_wall_strace"
  echo "stream_total_ms_wall_strace=$stream_total_ms_wall_strace"
  echo "ttft_ms_wall_rocprof=$ttft_ms_wall_rocprof"
  echo "stream_total_ms_wall_rocprof=$stream_total_ms_wall_rocprof"
  echo "phase_split_status_proxy=$phase_split_status_proxy"
  echo "phase_split_method=$phase_split_method"
  echo "prefill_kernel_tensile_like_rows=$prefill_kernel_tensile_like_rows"
  echo "decode_kernel_tensile_like_rows=$decode_kernel_tensile_like_rows"
  echo
  echo "--- gate ---"
  echo "fallback_confirmed=$fallback_confirmed"
  echo "dispatch_confirmed=$dispatch_confirmed"
  echo "direct_rocblas_or_tensile_dispatch=$direct_rocblas_or_tensile_dispatch"
  echo "link_status=$link_status"
} > "$LINK_SUMMARY"

echo "summary=$LINK_SUMMARY"
