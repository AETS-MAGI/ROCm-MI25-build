#!/usr/bin/env bash

set -euo pipefail

# Sweep ROCBLAS_LAYER values on top of g4-fallback-strace-check.sh
# and summarize which setting exposes the most rocBLAS-side visibility.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-${1:-tinyllama:latest}}"
PROMPT="${PROMPT:-Generate a short note about rocBLAS layer logging on gfx900.}"
NUM_PREDICT="${NUM_PREDICT:-96}"
TEMPERATURE="${TEMPERATURE:-0.1}"
HOST="${HOST:-127.0.0.1:11534}"

LAYER_LIST="${LAYER_LIST:-1,8,9,15,63}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"

# Optional verbose backend hints for ROCm docs troubleshooting.
ROCBLAS_VERBOSE_TENSILE_ERROR="${ROCBLAS_VERBOSE_TENSILE_ERROR:-0}"
ROCBLAS_VERBOSE_HIPBLASLT_ERROR="${ROCBLAS_VERBOSE_HIPBLASLT_ERROR:-0}"

mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
TSV="$LOG_DIR/g4_rocblas_layer_sweep_${MODEL_TAG}_${TS}.tsv"
SUMMARY="$LOG_DIR/g4_rocblas_layer_sweep_${MODEL_TAG}_${TS}.txt"

read_kv() {
  local file="$1"
  local key="$2"
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

extract_summary_path() {
  awk -F= '/^summary=/{print $2}' | tail -n 1
}

count_patterns() {
  local file="$1"
  local pattern="$2"
  if [[ -f "$file" ]]; then
    rg -n -i "$pattern" "$file" | wc -l | tr -d ' '
  else
    echo "0"
  fi
}

{
  printf "timestamp\tmodel\tlayer\ttrace_lines\ttrace_handle_lines\ttrace_gemm_lines\ttrace_internal_like_lines\ttrace_backend_like_lines\tbench_lines\tprofile_lines\tfallback_dat_openat\tfallback_hsaco_openat\tlibggml_hip_openat\tsummary_path\ttrace_path\tbench_path\tprofile_path\n"
} > "$TSV"

IFS=',' read -r -a layers <<< "$LAYER_LIST"

for layer in "${layers[@]}"; do
  layer="$(echo "$layer" | xargs)"
  if [[ -z "$layer" ]]; then
    continue
  fi

  out="$(
    HOST="$HOST" \
    MODEL="$MODEL" \
    PROMPT="$PROMPT" \
    NUM_PREDICT="$NUM_PREDICT" \
    TEMPERATURE="$TEMPERATURE" \
    PROBE_ROCBLAS_LOG=1 \
    STRACE_TIMESTAMP=1 \
    ROCBLAS_LAYER="$layer" \
    ROCBLAS_VERBOSE_TENSILE_ERROR="$ROCBLAS_VERBOSE_TENSILE_ERROR" \
    ROCBLAS_VERBOSE_HIPBLASLT_ERROR="$ROCBLAS_VERBOSE_HIPBLASLT_ERROR" \
    "$SCRIPT_DIR/g4-fallback-strace-check.sh"
  )"

  summary_path="$(printf '%s\n' "$out" | extract_summary_path)"
  if [[ -z "$summary_path" || ! -f "$summary_path" ]]; then
    echo "ERROR: failed to get summary for layer=$layer" >&2
    printf '%s\n' "$out" >&2
    exit 2
  fi

  trace_path="$(read_kv "$summary_path" "ROCBLAS_TRACE_LOG")"
  bench_path="$(read_kv "$summary_path" "ROCBLAS_BENCH_LOG")"
  profile_path="$(read_kv "$summary_path" "ROCBLAS_PROFILE_LOG")"

  trace_lines="$(to_int_or_zero "$(read_kv "$summary_path" "rocblas_trace_lines")")"
  trace_handle_lines="$(to_int_or_zero "$(read_kv "$summary_path" "rocblas_trace_handle_lines")")"
  trace_gemm_lines="$(to_int_or_zero "$(read_kv "$summary_path" "rocblas_trace_gemm_lines")")"
  fallback_dat_openat="$(to_int_or_zero "$(read_kv "$summary_path" "fallback_dat_openat")")"
  fallback_hsaco_openat="$(to_int_or_zero "$(read_kv "$summary_path" "fallback_hsaco_openat")")"
  libggml_hip_openat="$(to_int_or_zero "$(read_kv "$summary_path" "libggml_hip_openat")")"

  trace_internal_like_lines="$(count_patterns "$trace_path" "internal|backend|atomics_not_allowed|solution|tensile_host")"
  trace_backend_like_lines="$(count_patterns "$trace_path" "tensile|hipblaslt|gemm|matmul|solution")"
  bench_lines=0
  profile_lines=0
  if [[ -f "$bench_path" ]]; then
    bench_lines="$(wc -l < "$bench_path" | tr -d ' ')"
  fi
  if [[ -f "$profile_path" ]]; then
    profile_lines="$(wc -l < "$profile_path" | tr -d ' ')"
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$TS" "$MODEL" "$layer" \
    "$trace_lines" "$trace_handle_lines" "$trace_gemm_lines" \
    "$trace_internal_like_lines" "$trace_backend_like_lines" \
    "$bench_lines" "$profile_lines" \
    "$fallback_dat_openat" "$fallback_hsaco_openat" "$libggml_hip_openat" \
    "$summary_path" "$trace_path" "$bench_path" "$profile_path" >> "$TSV"
done

best_layer="$(awk -F'\t' 'NR>1 { score=$6*100000 + $8*1000 + $7*100 + $4; if(score>best){best=score;row=$0;layer=$3} } END{print layer}' "$TSV")"
best_row="$(awk -F'\t' 'NR>1 { score=$6*100000 + $8*1000 + $7*100 + $4; if(score>best){best=score;row=$0} } END{print row}' "$TSV")"

{
  echo "timestamp=$TS"
  echo "model=$MODEL"
  echo "host=$HOST"
  echo "num_predict=$NUM_PREDICT"
  echo "temperature=$TEMPERATURE"
  echo "layer_list=$LAYER_LIST"
  echo "rocblas_verbose_tensile_error=$ROCBLAS_VERBOSE_TENSILE_ERROR"
  echo "rocblas_verbose_hipblaslt_error=$ROCBLAS_VERBOSE_HIPBLASLT_ERROR"
  echo "tsv=$TSV"
  echo
  echo "--- per-layer table ---"
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t' "$TSV"
  else
    cat "$TSV"
  fi
  echo
  echo "--- heuristic best layer (visibility score) ---"
  echo "best_layer=${best_layer:-none}"
  if [[ -n "$best_row" ]]; then
    echo "best_row=$best_row"
  fi
  echo
  echo "score formula:"
  echo "  trace_gemm_lines*100000 + trace_backend_like_lines*1000 + trace_internal_like_lines*100 + trace_lines"
} > "$SUMMARY"

echo "summary=$SUMMARY"
