#!/usr/bin/env bash

set -euo pipefail

# Stream-mode phase window check:
# - enables STREAM=1 for both strace and rocprof probes
# - captures TTFT (wall) and phase-split proxy from rocprof summary

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-gpt-oss:latest}"
PROMPT="${PROMPT:-Write a concise technical note about fallback and direct dispatch verification on gfx900 MI25. Include short bullet-like lines in plain text.}"
NUM_PREDICT="${NUM_PREDICT:-128}"
TEMPERATURE="${TEMPERATURE:-0.1}"
NUM_CTX="${NUM_CTX:-8192}"
NUM_BATCH="${NUM_BATCH:-512}"
NUM_THREAD="${NUM_THREAD:-}"
KEEP_ALIVE="${KEEP_ALIVE:-5m}"

ROCBLAS_LAYER="${ROCBLAS_LAYER:-9}"
ROCBLAS_VERBOSE_TENSILE_ERROR="${ROCBLAS_VERBOSE_TENSILE_ERROR:-0}"
ROCBLAS_VERBOSE_HIPBLASLT_ERROR="${ROCBLAS_VERBOSE_HIPBLASLT_ERROR:-0}"

STRACE_HOST="${STRACE_HOST:-127.0.0.1:11534}"
ROCPROF_HOST="${ROCPROF_HOST:-127.0.0.1:11634}"

LOG_DIR="${LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
mkdir -p "$LOG_DIR" "$RAW_LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
SUMMARY="$LOG_DIR/g4_stream_phase_window_${MODEL_TAG}_${TS}.txt"

extract_summary_path() {
  awk -F= '/^summary=/{print $2}' | tail -n 1
}

read_kv() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file"
}

out="$(
  MODEL="$MODEL" \
  PROMPT="$PROMPT" \
  NUM_PREDICT="$NUM_PREDICT" \
  TEMPERATURE="$TEMPERATURE" \
  NUM_CTX="$NUM_CTX" \
  NUM_BATCH="$NUM_BATCH" \
  NUM_THREAD="$NUM_THREAD" \
  KEEP_ALIVE="$KEEP_ALIVE" \
  STREAM=1 \
  RAW_LOG_DIR="$RAW_LOG_DIR" \
  STRACE_HOST="$STRACE_HOST" \
  ROCPROF_HOST="$ROCPROF_HOST" \
  ROCBLAS_LAYER="$ROCBLAS_LAYER" \
  ROCBLAS_VERBOSE_TENSILE_ERROR="$ROCBLAS_VERBOSE_TENSILE_ERROR" \
  ROCBLAS_VERBOSE_HIPBLASLT_ERROR="$ROCBLAS_VERBOSE_HIPBLASLT_ERROR" \
  "$SCRIPT_DIR/g4-fallback-dispatch-link-check.sh"
)"

link_summary="$(printf '%s\n' "$out" | extract_summary_path)"
if [[ -z "$link_summary" || ! -f "$link_summary" ]]; then
  echo "ERROR: failed to resolve link summary path" >&2
  printf '%s\n' "$out" >&2
  exit 2
fi

strace_summary="$(read_kv "$link_summary" "strace_summary")"
rocprof_summary="$(read_kv "$link_summary" "rocprof_summary")"

{
  echo "timestamp=$TS"
  echo "model=$MODEL"
  echo "num_predict=$NUM_PREDICT"
  echo "temperature=$TEMPERATURE"
  echo "num_ctx=$NUM_CTX"
  echo "num_batch=$NUM_BATCH"
  echo "num_thread=$NUM_THREAD"
  echo "keep_alive=$KEEP_ALIVE"
  echo "stream=1"
  echo "raw_log_dir=$RAW_LOG_DIR"
  echo "link_summary=$link_summary"
  echo "strace_summary=$strace_summary"
  echo "rocprof_summary=$rocprof_summary"
  echo
  echo "--- stream timing ---"
  echo "ttft_ms_wall_strace=$(read_kv "$link_summary" "ttft_ms_wall_strace")"
  echo "stream_total_ms_wall_strace=$(read_kv "$link_summary" "stream_total_ms_wall_strace")"
  echo "ttft_ms_wall_rocprof=$(read_kv "$link_summary" "ttft_ms_wall_rocprof")"
  echo "stream_total_ms_wall_rocprof=$(read_kv "$link_summary" "stream_total_ms_wall_rocprof")"
  echo
  echo "--- phase split proxy ---"
  echo "phase_split_status_proxy=$(read_kv "$link_summary" "phase_split_status_proxy")"
  echo "phase_split_method=$(read_kv "$link_summary" "phase_split_method")"
  echo "prefill_kernel_tensile_like_rows=$(read_kv "$link_summary" "prefill_kernel_tensile_like_rows")"
  echo "decode_kernel_tensile_like_rows=$(read_kv "$link_summary" "decode_kernel_tensile_like_rows")"
  echo
  echo "--- gate ---"
  echo "direct_rocblas_or_tensile_dispatch=$(read_kv "$link_summary" "direct_rocblas_or_tensile_dispatch")"
  echo "fallback_confirmed=$(read_kv "$link_summary" "fallback_confirmed")"
  echo "dispatch_confirmed=$(read_kv "$link_summary" "dispatch_confirmed")"
  echo "link_status=$(read_kv "$link_summary" "link_status")"
} > "$SUMMARY"

echo "summary=$SUMMARY"
