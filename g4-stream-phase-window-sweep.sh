#!/usr/bin/env bash

set -euo pipefail

# Sweep stream-window probe over NUM_PREDICT values and aggregate TTFT/phase metrics.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-gpt-oss:latest}"
PROMPT="${PROMPT:-Write a concise technical note about fallback and direct dispatch verification on gfx900 MI25. Include short bullet-like lines in plain text.}"
NUM_PREDICT_LIST="${NUM_PREDICT_LIST:-64,128,256,512,1024}"
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

LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
mkdir -p "$LOG_DIR" "$RAW_LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
OUT_TSV="$LOG_DIR/g4_stream_phase_window_sweep_${MODEL_TAG}_${TS}.tsv"
OUT_SUMMARY="$LOG_DIR/g4_stream_phase_window_sweep_${MODEL_TAG}_${TS}.txt"

read_kv() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file"
}

extract_summary_path() {
  awk -F= '/^summary=/{print $2}' | tail -n 1
}

IFS=',' read -r -a predict_list <<< "$NUM_PREDICT_LIST"

printf '%s\n' "timestamp	model	num_predict	status	ttft_ms_wall_strace	ttft_ms_wall_rocprof	stream_total_ms_wall_strace	stream_total_ms_wall_rocprof	strace_first_token_channel	rocprof_first_token_channel	phase_split_status_proxy	prefill_kernel_tensile_like_rows	decode_kernel_tensile_like_rows	direct_rocblas_or_tensile_dispatch	fallback_confirmed	dispatch_confirmed	link_status	summary_path	link_summary	strace_summary	rocprof_summary" > "$OUT_TSV"

for np in "${predict_list[@]}"; do
  np="$(echo "$np" | xargs)"
  [[ -z "$np" ]] && continue

  set +e
  out="$(
    MODEL="$MODEL" \
    PROMPT="$PROMPT" \
    NUM_PREDICT="$np" \
    TEMPERATURE="$TEMPERATURE" \
    NUM_CTX="$NUM_CTX" \
    NUM_BATCH="$NUM_BATCH" \
    NUM_THREAD="$NUM_THREAD" \
    KEEP_ALIVE="$KEEP_ALIVE" \
    ROCBLAS_LAYER="$ROCBLAS_LAYER" \
    ROCBLAS_VERBOSE_TENSILE_ERROR="$ROCBLAS_VERBOSE_TENSILE_ERROR" \
    ROCBLAS_VERBOSE_HIPBLASLT_ERROR="$ROCBLAS_VERBOSE_HIPBLASLT_ERROR" \
    STRACE_HOST="$STRACE_HOST" \
    ROCPROF_HOST="$ROCPROF_HOST" \
    LOG_DIR="$LOG_DIR" \
    RAW_LOG_DIR="$RAW_LOG_DIR" \
    "$SCRIPT_DIR/g4-stream-phase-window-check.sh" 2>&1
  )"
  rc=$?
  set -e

  summary_path="$(printf '%s\n' "$out" | extract_summary_path)"
  if [[ $rc -ne 0 || -z "$summary_path" || ! -f "$summary_path" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$TS" "$MODEL" "$np" "failed" \
      "0" "0" "0" "0" "unknown" "unknown" "unknown" "0" "0" "0" "0" "0" "failed" \
      "" "" "" "" >> "$OUT_TSV"
    continue
  fi

  link_summary="$(read_kv "$summary_path" "link_summary")"
  strace_summary="$(read_kv "$summary_path" "strace_summary")"
  rocprof_summary="$(read_kv "$summary_path" "rocprof_summary")"

  ttft_ms_wall_strace="$(read_kv "$summary_path" "ttft_ms_wall_strace")"
  ttft_ms_wall_rocprof="$(read_kv "$summary_path" "ttft_ms_wall_rocprof")"
  stream_total_ms_wall_strace="$(read_kv "$summary_path" "stream_total_ms_wall_strace")"
  stream_total_ms_wall_rocprof="$(read_kv "$summary_path" "stream_total_ms_wall_rocprof")"
  phase_split_status_proxy="$(read_kv "$summary_path" "phase_split_status_proxy")"
  prefill_kernel_tensile_like_rows="$(read_kv "$summary_path" "prefill_kernel_tensile_like_rows")"
  decode_kernel_tensile_like_rows="$(read_kv "$summary_path" "decode_kernel_tensile_like_rows")"

  strace_first_token_channel="$(read_kv "$strace_summary" "stream_first_token_channel")"
  rocprof_first_token_channel="$(read_kv "$rocprof_summary" "stream_first_token_channel")"

  direct="$(read_kv "$summary_path" "direct_rocblas_or_tensile_dispatch")"
  fallback="$(read_kv "$summary_path" "fallback_confirmed")"
  dispatch="$(read_kv "$summary_path" "dispatch_confirmed")"
  link_status="$(read_kv "$summary_path" "link_status")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TS" "$MODEL" "$np" "ok" \
    "$ttft_ms_wall_strace" "$ttft_ms_wall_rocprof" \
    "$stream_total_ms_wall_strace" "$stream_total_ms_wall_rocprof" \
    "$strace_first_token_channel" "$rocprof_first_token_channel" \
    "$phase_split_status_proxy" "$prefill_kernel_tensile_like_rows" "$decode_kernel_tensile_like_rows" \
    "$direct" "$fallback" "$dispatch" "$link_status" \
    "$summary_path" "$link_summary" "$strace_summary" "$rocprof_summary" >> "$OUT_TSV"
done

ok_cases="$(awk -F'\t' 'NR>1 && $4=="ok" { c++ } END { print c+0 }' "$OUT_TSV")"
failed_cases="$(awk -F'\t' 'NR>1 && $4!="ok" { c++ } END { print c+0 }' "$OUT_TSV")"
decode_sig_cases="$(awk -F'\t' 'NR>1 && $11=="decode_signature_detected" { c++ } END { print c+0 }' "$OUT_TSV")"
prefill_sig_cases="$(awk -F'\t' 'NR>1 && $11=="prefill_dominant_signature" { c++ } END { print c+0 }' "$OUT_TSV")"

{
  echo "timestamp=$TS"
  echo "model=$MODEL"
  echo "num_predict_list=$NUM_PREDICT_LIST"
  echo "temperature=$TEMPERATURE"
  echo "num_ctx=$NUM_CTX"
  echo "num_batch=$NUM_BATCH"
  echo "num_thread=$NUM_THREAD"
  echo "keep_alive=$KEEP_ALIVE"
  echo "rocblas_layer=$ROCBLAS_LAYER"
  echo "strace_host=$STRACE_HOST"
  echo "rocprof_host=$ROCPROF_HOST"
  echo "raw_log_dir=$RAW_LOG_DIR"
  echo "tsv=$OUT_TSV"
  echo
  echo "--- counts ---"
  echo "ok_cases=$ok_cases"
  echo "failed_cases=$failed_cases"
  echo "decode_signature_cases=$decode_sig_cases"
  echo "prefill_dominant_cases=$prefill_sig_cases"
  echo
  echo "--- rows ---"
  cat "$OUT_TSV"
} > "$OUT_SUMMARY"

echo "summary=$OUT_SUMMARY"
echo "tsv=$OUT_TSV"
