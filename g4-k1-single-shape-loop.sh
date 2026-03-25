#!/usr/bin/env bash

set -euo pipefail

# K1 entry loop (shape-first, one-point A/B):
# - Keeps anchor workload fixed
# - Changes one low-level knob only: ROCBLAS_TENSILE_LIBPATH
# - Collects link/shape/metrics evidence in one canonical summary

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

LOG_DIR="${LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
mkdir -p "$LOG_DIR" "$RAW_LOG_DIR"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"

MODEL="${MODEL:-gpt-oss:latest}"
PROMPT="${PROMPT:-Generate a concise note about fallback and kernel dispatch on gfx900.}"
NUM_PREDICT="${NUM_PREDICT:-128}"
NUM_CTX="${NUM_CTX:-8192}"
NUM_BATCH="${NUM_BATCH:-512}"
NUM_THREAD="${NUM_THREAD:-}"
KEEP_ALIVE="${KEEP_ALIVE:-5m}"
TEMPERATURE="${TEMPERATURE:-0.1}"
STREAM="${STREAM:-1}"
ROCBLAS_LAYER="${ROCBLAS_LAYER:-9}"

TARGET_M="${TARGET_M:-512}"
TARGET_N="${TARGET_N:-512}"
TARGET_K="${TARGET_K:-2880}"
TARGET_SHAPE="${TARGET_M}x${TARGET_N}x${TARGET_K}"

AETS_LIBPATH="${AETS_LIBPATH:-$WORKSPACE_ROOT/ROCm-repos_AETS/rocBLAS/build-mi25-gfx900/release/rocblas-install/lib/rocblas/library}"
SYSTEM_LIBPATH="${SYSTEM_LIBPATH:-/opt/rocm-7.2.0/lib/rocblas/library}"

OUT_TSV="$LOG_DIR/g4_k1_single_shape_loop_${RUN_TAG}.tsv"
OUT_TXT="$LOG_DIR/g4_k1_single_shape_loop_${RUN_TAG}.txt"
INDEX_TSV="$LOG_DIR/g4_k1_single_shape_loop_${RUN_TAG}_index.tsv"

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

num_or_zero() {
  local v="${1:-}"
  if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "$v"
  else
    echo "0"
  fi
}

is_positive_num() {
  local v="${1:-0}"
  awk -v n="$v" 'BEGIN { exit (n + 0 > 0) ? 0 : 1 }'
}

calc_tok_s_from_json() {
  local gen_json="$1"
  if [[ -z "$gen_json" || ! -f "$gen_json" ]]; then
    echo "0"
    return 0
  fi
  local eval_count eval_duration_ns
  eval_count="$(jq -r '.eval_count // 0' "$gen_json" 2>/dev/null || echo 0)"
  eval_duration_ns="$(jq -r '.eval_duration // 0' "$gen_json" 2>/dev/null || echo 0)"
  awk -v c="$eval_count" -v d="$eval_duration_ns" 'BEGIN {
    if (d <= 0) { print "0"; exit }
    printf "%.4f", c / (d / 1000000000.0)
  }'
}

calc_total_ms() {
  local preferred_wall_ms="$1"
  local gen_json="$2"
  if is_positive_num "$preferred_wall_ms"; then
    echo "$preferred_wall_ms"
    return 0
  fi
  if [[ -z "$gen_json" || ! -f "$gen_json" ]]; then
    echo "0"
    return 0
  fi
  local total_duration_ns
  total_duration_ns="$(jq -r '.total_duration // 0' "$gen_json" 2>/dev/null || echo 0)"
  awk -v d="$total_duration_ns" 'BEGIN {
    if (d <= 0) { print "0"; exit }
    printf "%.3f", d / 1000000.0
  }'
}

copy_with_canonical_name() {
  local src="$1"
  local lane="$2"
  local kind="$3"
  local dst="$LOG_DIR/g4_k1_${RUN_TAG}_${lane}_${kind}"
  if [[ -n "$src" && -f "$src" ]]; then
    cp "$src" "$dst"
    echo -e "${lane}\t${kind}\t${dst}\t${src}" >> "$INDEX_TSV"
    echo "$dst"
    return 0
  fi
  echo ""
}

shape_hits_from_tsv() {
  local tsv="$1"
  if [[ -z "$tsv" || ! -f "$tsv" ]]; then
    echo "0"
    return 0
  fi
  awk -F'\t' -v m="$TARGET_M" -v n="$TARGET_N" -v k="$TARGET_K" '
    NR > 1 && $5 == m && $6 == n && $7 == k { s += $13 }
    END { print s + 0 }
  ' "$tsv"
}

run_lane() {
  local lane="$1"
  local libpath="$2"

  local out link_summary strace_summary rocprof_summary
  out="$(
    MODEL="$MODEL" \
    PROMPT="$PROMPT" \
    NUM_PREDICT="$NUM_PREDICT" \
    TEMPERATURE="$TEMPERATURE" \
    NUM_CTX="$NUM_CTX" \
    NUM_BATCH="$NUM_BATCH" \
    NUM_THREAD="$NUM_THREAD" \
    KEEP_ALIVE="$KEEP_ALIVE" \
    STREAM="$STREAM" \
    ROCBLAS_LAYER="$ROCBLAS_LAYER" \
    ROCBLAS_TENSILE_LIBPATH="$libpath" \
    LOG_DIR="$LOG_DIR" \
    RAW_LOG_DIR="$RAW_LOG_DIR" \
    "$SCRIPT_DIR/g4-fallback-dispatch-link-check.sh"
  )"
  link_summary="$(printf '%s\n' "$out" | extract_summary_path)"
  if [[ -z "$link_summary" || ! -f "$link_summary" ]]; then
    echo "ERROR: lane=${lane} failed to resolve link summary" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  strace_summary="$(read_kv "$link_summary" "strace_summary")"
  rocprof_summary="$(read_kv "$link_summary" "rocprof_summary")"

  local rocblas_trace_log shape_out shape_summary shape_tsv shape_hits
  rocblas_trace_log="$(read_kv "$strace_summary" "ROCBLAS_TRACE_LOG")"
  shape_summary=""
  shape_tsv=""
  if [[ -n "$rocblas_trace_log" && -f "$rocblas_trace_log" ]]; then
    shape_out="$(
      TRACE_LOG="$rocblas_trace_log" \
      LOG_DIR="$LOG_DIR" \
      "$SCRIPT_DIR/summarize-rocblas-gemm-shapes.sh"
    )"
    shape_summary="$(printf '%s\n' "$shape_out" | awk -F= '/^summary=/{print $2}' | tail -n 1)"
    shape_tsv="$(printf '%s\n' "$shape_out" | awk -F= '/^tsv=/{print $2}' | tail -n 1)"
  fi
  shape_hits="$(shape_hits_from_tsv "$shape_tsv")"

  local gen_json ttft_ms total_ms tok_s
  gen_json="$(read_kv "$strace_summary" "GEN_LOG")"
  if [[ -z "$gen_json" ]]; then
    gen_json="$(read_kv "$rocprof_summary" "GEN_LOG")"
  fi
  ttft_ms="$(num_or_zero "$(read_kv "$strace_summary" "ttft_ms_wall")")"
  total_ms="$(calc_total_ms "$(read_kv "$strace_summary" "stream_total_ms_wall")" "$gen_json")"
  tok_s="$(calc_tok_s_from_json "$gen_json")"

  local can_link can_strace can_rocprof can_shape_tsv can_shape_summary
  can_link="$(copy_with_canonical_name "$link_summary" "$lane" "link_summary.txt")"
  can_strace="$(copy_with_canonical_name "$strace_summary" "$lane" "strace_summary.txt")"
  can_rocprof="$(copy_with_canonical_name "$rocprof_summary" "$lane" "rocprof_summary.txt")"
  can_shape_tsv="$(copy_with_canonical_name "$shape_tsv" "$lane" "rocblas_gemm_shapes.tsv")"
  can_shape_summary="$(copy_with_canonical_name "$shape_summary" "$lane" "rocblas_gemm_shapes.txt")"

  echo -e "${lane}\t${libpath}\t${TARGET_SHAPE}\t$(read_kv "$link_summary" "fallback_confirmed")\t$(read_kv "$link_summary" "dispatch_confirmed")\t$(read_kv "$link_summary" "direct_rocblas_or_tensile_dispatch")\t$(read_kv "$link_summary" "fallback_dat_openat")\t$(read_kv "$link_summary" "fallback_hsaco_openat")\t$(read_kv "$link_summary" "rocblas_trace_gemm_lines")\t$(read_kv "$link_summary" "kernel_dispatch_rows")\t$(read_kv "$link_summary" "kernel_tensile_like_rows")\t$(read_kv "$link_summary" "phase_split_status_proxy")\t${shape_hits}\t${ttft_ms}\t${total_ms}\t${tok_s}\t${can_link}\t${can_strace}\t${can_rocprof}\t${can_shape_tsv}\t${can_shape_summary}" >> "$OUT_TSV"
}

{
  echo -e "lane\trocblas_tensile_libpath\ttarget_shape_mnk\tfallback_confirmed\tdispatch_confirmed\tdirect_rocblas_or_tensile_dispatch\tfallback_dat_openat\tfallback_hsaco_openat\trocblas_trace_gemm_lines\tkernel_dispatch_rows\tkernel_tensile_like_rows\tphase_split_status_proxy\tshape_target_hits\tttft_ms\ttotal_ms\ttok_s\tcanonical_link_summary\tcanonical_strace_summary\tcanonical_rocprof_summary\tcanonical_shape_tsv\tcanonical_shape_summary"
} > "$OUT_TSV"

{
  echo -e "lane\tkind\tcanonical_path\tsource_path"
} > "$INDEX_TSV"

run_lane "aets" "$AETS_LIBPATH"
run_lane "system" "$SYSTEM_LIBPATH"

{
  echo "run_tag=$RUN_TAG"
  echo "model=$MODEL"
  echo "target_shape=$TARGET_SHAPE"
  echo "anchor=num_batch=$NUM_BATCH,num_ctx=$NUM_CTX,num_predict=$NUM_PREDICT,keep_alive=$KEEP_ALIVE,stream=$STREAM,rocblas_layer=$ROCBLAS_LAYER"
  echo "out_tsv=$OUT_TSV"
  echo "index_tsv=$INDEX_TSV"
  echo
  echo "--- lane rows ---"
  column -ts $'\t' "$OUT_TSV" | sed 's/^/  /'
  echo
  echo "note=one-point A/B only: ROCBLAS_TENSILE_LIBPATH changed between lanes"
  echo "note2=observation-first record; no kernel-level causal mapping claim"
} > "$OUT_TXT"

echo "summary=$OUT_TXT"
echo "tsv=$OUT_TSV"
echo "index=$INDEX_TSV"
