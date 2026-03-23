#!/usr/bin/env bash

set -euo pipefail

# Phase split helper for G4 anchor:
# - run a prefill-proxy case (low num_predict)
# - run a full case (baseline num_predict)
# - compare shape/gemm signatures and emit decode-proxy deltas
#
# Note:
# This script uses "full - prefill_proxy" as a decode-proxy estimate.
# It does not claim exact token-level dispatch attribution.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-gpt-oss:latest}"
PROMPT="${PROMPT:-Write a concise technical note about fallback and direct dispatch verification on gfx900 MI25. Include short bullet-like lines in plain text.}"

PREFILL_NUM_PREDICT="${PREFILL_NUM_PREDICT:-1}"
FULL_NUM_PREDICT="${FULL_NUM_PREDICT:-128}"

NUM_CTX="${NUM_CTX:-8192}"
NUM_BATCH="${NUM_BATCH:-512}"
NUM_THREAD="${NUM_THREAD:-}"
KEEP_ALIVE="${KEEP_ALIVE:-5m}"
TEMPERATURE="${TEMPERATURE:-0.1}"
RUNS_PER_CASE="${RUNS_PER_CASE:-1}"

TARGET_SHAPES="${TARGET_SHAPES:-512x512x2880,2880x512x4096,4096x512x2880}"

ROCBLAS_LAYER="${ROCBLAS_LAYER:-9}"
ROCBLAS_VERBOSE_TENSILE_ERROR="${ROCBLAS_VERBOSE_TENSILE_ERROR:-0}"
ROCBLAS_VERBOSE_HIPBLASLT_ERROR="${ROCBLAS_VERBOSE_HIPBLASLT_ERROR:-0}"

HOST_STRACE="${HOST_STRACE:-127.0.0.1:11534}"
HOST_ROCPROF="${HOST_ROCPROF:-127.0.0.1:11634}"

LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
mkdir -p "$LOG_DIR" "$RAW_LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
SUMMARY="$LOG_DIR/g4_prefill_decode_split_${MODEL_TAG}_${TS}.txt"
COMPARE_TSV="$LOG_DIR/g4_prefill_decode_shape_compare_${MODEL_TAG}_${TS}.tsv"

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

json_val() {
  local json_file="$1"
  local key="$2"
  if [[ -f "$json_file" ]]; then
    jq -r --arg k "$key" '.[$k] // 0' "$json_file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

run_anchor_case() {
  local label="$1"
  local np="$2"
  local out
  local summary_path
  local tsv_path

  out="$(
    MODEL="$MODEL" \
    PROMPT="$PROMPT" \
    NUM_PREDICT_LIST="$np" \
    NUM_CTX_LIST="$NUM_CTX" \
    NUM_BATCH_LIST="$NUM_BATCH" \
    NUM_THREAD_LIST="$NUM_THREAD" \
    KEEP_ALIVE_LIST="$KEEP_ALIVE" \
    TEMPERATURE="$TEMPERATURE" \
    RUNS_PER_CASE="$RUNS_PER_CASE" \
    TARGET_SHAPES="$TARGET_SHAPES" \
    ROCBLAS_LAYER="$ROCBLAS_LAYER" \
    ROCBLAS_VERBOSE_TENSILE_ERROR="$ROCBLAS_VERBOSE_TENSILE_ERROR" \
    ROCBLAS_VERBOSE_HIPBLASLT_ERROR="$ROCBLAS_VERBOSE_HIPBLASLT_ERROR" \
    HOST_STRACE="$HOST_STRACE" \
    HOST_ROCPROF="$HOST_ROCPROF" \
    LOG_DIR="$LOG_DIR" \
    RAW_LOG_DIR="$RAW_LOG_DIR" \
    "$SCRIPT_DIR/g4-gptoss-anchor-shape-sweep.sh"
  )"

  summary_path="$(printf '%s\n' "$out" | extract_summary_path)"
  if [[ -z "$summary_path" || ! -f "$summary_path" ]]; then
    echo "ERROR: failed to capture summary path for $label" >&2
    printf '%s\n' "$out" >&2
    exit 2
  fi

  tsv_path="$(read_kv "$summary_path" "tsv")"
  if [[ -z "$tsv_path" || ! -f "$tsv_path" ]]; then
    echo "ERROR: failed to capture tsv path for $label" >&2
    echo "summary=$summary_path" >&2
    exit 3
  fi

  echo "$summary_path"$'\t'"$tsv_path"
}

extract_first_ok_row() {
  local tsv_path="$1"
  awk -F'\t' 'NR>1 && $12=="ok" { print; exit }' "$tsv_path"
}

extract_shape_hits_from_first_ok() {
  local tsv_path="$1"
  awk -F'\t' '
    NR==1 {
      for (i = 1; i <= NF; i++) {
        h[i] = $i
      }
      next
    }
    NR>1 && $12=="ok" {
      for (i = 24; i <= NF; i++) {
        if (h[i] ~ /^shape_/) {
          printf("%s\t%d\n", h[i], $i + 0)
        }
      }
      exit
    }
  ' "$tsv_path"
}

extract_case_metrics() {
  local tsv_path="$1"
  local prefix="$2"
  local row
  local strace_summary
  local rocprof_summary
  local link_summary
  local trace_log
  local gen_log

  row="$(extract_first_ok_row "$tsv_path")"
  if [[ -z "$row" ]]; then
    echo "${prefix}_ok=0"
    echo "${prefix}_direct=0"
    echo "${prefix}_fallback=0"
    echo "${prefix}_dispatch=0"
    echo "${prefix}_gemm_lines=0"
    echo "${prefix}_tensile_like_rows=0"
    echo "${prefix}_target_shape_hits_total=0"
    echo "${prefix}_prompt_eval_count=0"
    echo "${prefix}_eval_count=0"
    echo "${prefix}_total_duration_ns=0"
    echo "${prefix}_done_reason=unknown"
    echo "${prefix}_strace_summary="
    echo "${prefix}_rocprof_summary="
    echo "${prefix}_link_summary="
    echo "${prefix}_rocblas_trace_log="
    return 0
  fi

  strace_summary="$(printf '%s\n' "$row" | awk -F'\t' '{print $20}')"
  rocprof_summary="$(printf '%s\n' "$row" | awk -F'\t' '{print $21}')"
  link_summary="$(printf '%s\n' "$row" | awk -F'\t' '{print $22}')"
  trace_log="$(printf '%s\n' "$row" | awk -F'\t' '{print $23}')"
  gen_log="$(read_kv "$strace_summary" "GEN_LOG")"

  echo "${prefix}_ok=1"
  echo "${prefix}_direct=$(printf '%s\n' "$row" | awk -F'\t' '{print $14+0}')"
  echo "${prefix}_fallback=$(printf '%s\n' "$row" | awk -F'\t' '{print $15+0}')"
  echo "${prefix}_dispatch=$(printf '%s\n' "$row" | awk -F'\t' '{print $16+0}')"
  echo "${prefix}_gemm_lines=$(printf '%s\n' "$row" | awk -F'\t' '{print $17+0}')"
  echo "${prefix}_tensile_like_rows=$(printf '%s\n' "$row" | awk -F'\t' '{print $18+0}')"
  echo "${prefix}_target_shape_hits_total=$(printf '%s\n' "$row" | awk -F'\t' '{print $19+0}')"
  echo "${prefix}_prompt_eval_count=$(json_val "$gen_log" "prompt_eval_count")"
  echo "${prefix}_eval_count=$(json_val "$gen_log" "eval_count")"
  echo "${prefix}_total_duration_ns=$(json_val "$gen_log" "total_duration")"
  echo "${prefix}_done_reason=$(json_val "$gen_log" "done_reason")"
  echo "${prefix}_strace_summary=$strace_summary"
  echo "${prefix}_rocprof_summary=$rocprof_summary"
  echo "${prefix}_link_summary=$link_summary"
  echo "${prefix}_rocblas_trace_log=$trace_log"
}

IFS=$'\t' read -r PREFILL_SUMMARY PREFILL_TSV < <(run_anchor_case "prefill_proxy" "$PREFILL_NUM_PREDICT")
IFS=$'\t' read -r FULL_SUMMARY FULL_TSV < <(run_anchor_case "full" "$FULL_NUM_PREDICT")

PREFILL_SHAPES_FILE="$(mktemp)"
FULL_SHAPES_FILE="$(mktemp)"
METRICS_FILE="$(mktemp)"
trap 'rm -f "$PREFILL_SHAPES_FILE" "$FULL_SHAPES_FILE" "$METRICS_FILE"' EXIT

extract_shape_hits_from_first_ok "$PREFILL_TSV" > "$PREFILL_SHAPES_FILE"
extract_shape_hits_from_first_ok "$FULL_TSV" > "$FULL_SHAPES_FILE"

{
  extract_case_metrics "$PREFILL_TSV" "prefill"
  extract_case_metrics "$FULL_TSV" "full"
} > "$METRICS_FILE"

# shellcheck disable=SC1090
source "$METRICS_FILE"

{
  echo -e "shape\tprefill_hits\tfull_hits\tdecode_delta\tdecode_delta_positive"
  awk '
    FNR==NR { p[$1]=$2; keys[$1]=1; next }
             { f[$1]=$2; keys[$1]=1 }
    END {
      for (k in keys) {
        ph = (k in p ? p[k] : 0)
        fh = (k in f ? f[k] : 0)
        d = fh - ph
        dp = (d > 0 ? d : 0)
        printf("%s\t%d\t%d\t%d\t%d\n", k, ph, fh, d, dp)
      }
    }
  ' "$PREFILL_SHAPES_FILE" "$FULL_SHAPES_FILE" | sort
} > "$COMPARE_TSV"

decode_delta_gemm_lines=$((full_gemm_lines - prefill_gemm_lines))
decode_delta_target_hits=$((full_target_shape_hits_total - prefill_target_shape_hits_total))
decode_delta_eval_count=$((full_eval_count - prefill_eval_count))
decode_delta_gemm_lines_pos="$decode_delta_gemm_lines"
decode_delta_target_hits_pos="$decode_delta_target_hits"
if (( decode_delta_gemm_lines_pos < 0 )); then
  decode_delta_gemm_lines_pos=0
fi
if (( decode_delta_target_hits_pos < 0 )); then
  decode_delta_target_hits_pos=0
fi

phase_split_status="undetermined"
if (( full_ok == 1 && prefill_ok == 1 )); then
  if (( decode_delta_gemm_lines_pos == 0 && decode_delta_target_hits_pos == 0 )); then
    phase_split_status="prefill_dominant_signature"
  else
    phase_split_status="decode_signature_detected"
  fi
elif (( full_ok == 1 && prefill_ok == 0 )); then
  phase_split_status="prefill_probe_failed_full_ok"
elif (( full_ok == 0 && prefill_ok == 1 )); then
  phase_split_status="full_probe_failed_prefill_ok"
else
  phase_split_status="both_failed"
fi

{
  echo "timestamp=$TS"
  echo "model=$MODEL"
  echo "prompt=$PROMPT"
  echo "prefill_num_predict=$PREFILL_NUM_PREDICT"
  echo "full_num_predict=$FULL_NUM_PREDICT"
  echo "num_ctx=$NUM_CTX"
  echo "num_batch=$NUM_BATCH"
  echo "num_thread=$NUM_THREAD"
  echo "keep_alive=$KEEP_ALIVE"
  echo "temperature=$TEMPERATURE"
  echo "runs_per_case=$RUNS_PER_CASE"
  echo "target_shapes=$TARGET_SHAPES"
  echo "rocblas_layer=$ROCBLAS_LAYER"
  echo "rocblas_verbose_tensile_error=$ROCBLAS_VERBOSE_TENSILE_ERROR"
  echo "rocblas_verbose_hipblaslt_error=$ROCBLAS_VERBOSE_HIPBLASLT_ERROR"
  echo "host_strace=$HOST_STRACE"
  echo "host_rocprof=$HOST_ROCPROF"
  echo "raw_log_dir=$RAW_LOG_DIR"
  echo "prefill_summary=$PREFILL_SUMMARY"
  echo "prefill_tsv=$PREFILL_TSV"
  echo "full_summary=$FULL_SUMMARY"
  echo "full_tsv=$FULL_TSV"
  echo "shape_compare_tsv=$COMPARE_TSV"
  echo
  echo "--- prefill_proxy metrics ---"
  echo "prefill_ok=$prefill_ok"
  echo "prefill_direct=$prefill_direct"
  echo "prefill_fallback=$prefill_fallback"
  echo "prefill_dispatch=$prefill_dispatch"
  echo "prefill_gemm_lines=$prefill_gemm_lines"
  echo "prefill_tensile_like_rows=$prefill_tensile_like_rows"
  echo "prefill_target_shape_hits_total=$prefill_target_shape_hits_total"
  echo "prefill_prompt_eval_count=$prefill_prompt_eval_count"
  echo "prefill_eval_count=$prefill_eval_count"
  echo "prefill_total_duration_ns=$prefill_total_duration_ns"
  echo "prefill_done_reason=$prefill_done_reason"
  echo "prefill_strace_summary=$prefill_strace_summary"
  echo "prefill_rocprof_summary=$prefill_rocprof_summary"
  echo "prefill_link_summary=$prefill_link_summary"
  echo "prefill_rocblas_trace_log=$prefill_rocblas_trace_log"
  echo
  echo "--- full metrics ---"
  echo "full_ok=$full_ok"
  echo "full_direct=$full_direct"
  echo "full_fallback=$full_fallback"
  echo "full_dispatch=$full_dispatch"
  echo "full_gemm_lines=$full_gemm_lines"
  echo "full_tensile_like_rows=$full_tensile_like_rows"
  echo "full_target_shape_hits_total=$full_target_shape_hits_total"
  echo "full_prompt_eval_count=$full_prompt_eval_count"
  echo "full_eval_count=$full_eval_count"
  echo "full_total_duration_ns=$full_total_duration_ns"
  echo "full_done_reason=$full_done_reason"
  echo "full_strace_summary=$full_strace_summary"
  echo "full_rocprof_summary=$full_rocprof_summary"
  echo "full_link_summary=$full_link_summary"
  echo "full_rocblas_trace_log=$full_rocblas_trace_log"
  echo
  echo "--- decode_proxy (full - prefill_proxy) ---"
  echo "decode_delta_eval_count=$decode_delta_eval_count"
  echo "decode_delta_gemm_lines=$decode_delta_gemm_lines"
  echo "decode_delta_gemm_lines_positive=$decode_delta_gemm_lines_pos"
  echo "decode_delta_target_shape_hits=$decode_delta_target_hits"
  echo "decode_delta_target_shape_hits_positive=$decode_delta_target_hits_pos"
  echo "phase_split_status=$phase_split_status"
  echo
  echo "--- shape_decode_proxy ---"
  cat "$COMPARE_TSV"
} > "$SUMMARY"

echo "summary=$SUMMARY"
echo "shape_compare_tsv=$COMPARE_TSV"
