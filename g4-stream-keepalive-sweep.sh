#!/usr/bin/env bash

set -euo pipefail

# Sweep KEEP_ALIVE values on top of g4-stream-phase-window-sweep
# and aggregate rows into one comparison table.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-gpt-oss:latest}"
PROMPT="${PROMPT:-Write a concise technical note about fallback and direct dispatch verification on gfx900 MI25. Include short bullet-like lines in plain text.}"
KEEP_ALIVE_LIST="${KEEP_ALIVE_LIST:-10s,30s,5m}"
NUM_PREDICT_LIST="${NUM_PREDICT_LIST:-128}"
TEMPERATURE="${TEMPERATURE:-0.1}"
NUM_CTX="${NUM_CTX:-8192}"
NUM_BATCH="${NUM_BATCH:-512}"
NUM_THREAD="${NUM_THREAD:-}"

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
OUT_TSV="$LOG_DIR/g4_stream_keepalive_sweep_${MODEL_TAG}_${TS}.tsv"
OUT_SUMMARY="$LOG_DIR/g4_stream_keepalive_sweep_${MODEL_TAG}_${TS}.txt"

extract_key() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file"
}

extract_path_from_stdout() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k { print $2 }' | tail -n 1
}

IFS=',' read -r -a keep_alive_values <<< "$KEEP_ALIVE_LIST"

printf '%s\n' \
  "timestamp	model	keep_alive	num_predict	status	ttft_ms_wall_strace	ttft_ms_wall_rocprof	stream_total_ms_wall_strace	stream_total_ms_wall_rocprof	strace_first_token_channel	rocprof_first_token_channel	phase_split_status_proxy	prefill_kernel_tensile_like_rows	decode_kernel_tensile_like_rows	direct_rocblas_or_tensile_dispatch	fallback_confirmed	dispatch_confirmed	link_status	per_keepalive_summary	per_keepalive_tsv" \
  > "$OUT_TSV"

for ka in "${keep_alive_values[@]}"; do
  ka="$(echo "$ka" | xargs)"
  [[ -z "$ka" ]] && continue

  set +e
  run_out="$(
    MODEL="$MODEL" \
    PROMPT="$PROMPT" \
    NUM_PREDICT_LIST="$NUM_PREDICT_LIST" \
    TEMPERATURE="$TEMPERATURE" \
    NUM_CTX="$NUM_CTX" \
    NUM_BATCH="$NUM_BATCH" \
    NUM_THREAD="$NUM_THREAD" \
    KEEP_ALIVE="$ka" \
    ROCBLAS_LAYER="$ROCBLAS_LAYER" \
    ROCBLAS_VERBOSE_TENSILE_ERROR="$ROCBLAS_VERBOSE_TENSILE_ERROR" \
    ROCBLAS_VERBOSE_HIPBLASLT_ERROR="$ROCBLAS_VERBOSE_HIPBLASLT_ERROR" \
    STRACE_HOST="$STRACE_HOST" \
    ROCPROF_HOST="$ROCPROF_HOST" \
    LOG_DIR="$LOG_DIR" \
    RAW_LOG_DIR="$RAW_LOG_DIR" \
    "$SCRIPT_DIR/g4-stream-phase-window-sweep.sh" 2>&1
  )"
  rc=$?
  set -e

  per_summary="$(printf '%s\n' "$run_out" | extract_path_from_stdout "summary")"
  per_tsv="$(printf '%s\n' "$run_out" | extract_path_from_stdout "tsv")"

  if [[ $rc -ne 0 || -z "$per_tsv" || ! -f "$per_tsv" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$TS" "$MODEL" "$ka" "NA" "failed" \
      "0" "0" "0" "0" "unknown" "unknown" "unknown" "0" "0" "0" "0" "0" "failed" \
      "${per_summary:-}" "${per_tsv:-}" >> "$OUT_TSV"
    continue
  fi

  while IFS=$'\t' read -r row_ts row_model row_np row_status row_ttft_s row_ttft_r row_total_s row_total_r row_ch_s row_ch_r row_phase row_pref row_dec row_direct row_fb row_disp row_link _rest; do
    [[ "$row_ts" == "timestamp" ]] && continue
    [[ -z "$row_ts" ]] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$TS" "$MODEL" "$ka" "$row_np" "$row_status" \
      "$row_ttft_s" "$row_ttft_r" "$row_total_s" "$row_total_r" \
      "$row_ch_s" "$row_ch_r" "$row_phase" "$row_pref" "$row_dec" \
      "$row_direct" "$row_fb" "$row_disp" "$row_link" "$per_summary" "$per_tsv" >> "$OUT_TSV"
  done < "$per_tsv"
done

ok_cases="$(awk -F'\t' 'NR>1 && $5=="ok" { c++ } END { print c+0 }' "$OUT_TSV")"
failed_cases="$(awk -F'\t' 'NR>1 && $5!="ok" { c++ } END { print c+0 }' "$OUT_TSV")"
decode_sig_cases="$(awk -F'\t' 'NR>1 && $12=="decode_signature_detected" { c++ } END { print c+0 }' "$OUT_TSV")"
prefill_sig_cases="$(awk -F'\t' 'NR>1 && $12=="prefill_dominant_signature" { c++ } END { print c+0 }' "$OUT_TSV")"
unavailable_cases="$(awk -F'\t' 'NR>1 && $12=="unavailable" { c++ } END { print c+0 }' "$OUT_TSV")"

{
  echo "timestamp=$TS"
  echo "model=$MODEL"
  echo "keep_alive_list=$KEEP_ALIVE_LIST"
  echo "num_predict_list=$NUM_PREDICT_LIST"
  echo "temperature=$TEMPERATURE"
  echo "num_ctx=$NUM_CTX"
  echo "num_batch=$NUM_BATCH"
  echo "num_thread=$NUM_THREAD"
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
  echo "unavailable_cases=$unavailable_cases"
  echo
  echo "--- rows ---"
  cat "$OUT_TSV"
} > "$OUT_SUMMARY"

echo "summary=$OUT_SUMMARY"
echo "tsv=$OUT_TSV"
