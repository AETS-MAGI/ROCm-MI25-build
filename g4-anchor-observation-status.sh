#!/usr/bin/env bash

set -euo pipefail

# Minimal UX status layer for anchor-only observation.
# This script intentionally reports observation labels only and avoids
# kernel-level causal claims.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

LANE="${LANE:-baseline}" # baseline | side
MODEL="${MODEL:-gpt-oss:latest}"
NUM_PREDICT="${NUM_PREDICT:-128}"
TEMPERATURE="${TEMPERATURE:-0.1}"
NUM_CTX="${NUM_CTX:-8192}"
NUM_THREAD="${NUM_THREAD:-}"
KEEP_ALIVE="${KEEP_ALIVE:-5m}"
ROCBLAS_LAYER="${ROCBLAS_LAYER:-9}"

# If NUM_BATCH is not explicitly provided, select lane default.
NUM_BATCH="${NUM_BATCH:-}"
if [[ -z "$NUM_BATCH" ]]; then
  case "$LANE" in
    baseline) NUM_BATCH=512 ;;
    side) NUM_BATCH=1024 ;;
    *)
      echo "ERROR: unsupported LANE='$LANE' (expected: baseline|side)" >&2
      exit 2
      ;;
  esac
fi

TARGET_SHAPES="${TARGET_SHAPES:-}"
if [[ -z "$TARGET_SHAPES" ]]; then
  if [[ "$NUM_BATCH" == "512" ]]; then
    TARGET_SHAPES="512x512x2880,2880x512x4096,4096x512x2880"
  elif [[ "$NUM_BATCH" == "1024" ]]; then
    TARGET_SHAPES="512x1024x2880,2880x1024x4096,4096x1024x2880"
  else
    TARGET_SHAPES="512x512x2880,2880x512x4096,4096x512x2880"
  fi
fi

RUN_PROBE="${RUN_PROBE:-1}" # 1: execute probe, 0: parse existing STREAM_SUMMARY
STREAM_SUMMARY="${STREAM_SUMMARY:-}"

LOG_DIR="${LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
mkdir -p "$LOG_DIR" "$RAW_LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
OUT_SUMMARY="$LOG_DIR/g4_anchor_observation_status_${MODEL_TAG}_${TS}.txt"

read_kv() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file"
}

bool_label() {
  local v="$1"
  local yes="$2"
  local no="$3"
  if [[ "$v" == "1" ]]; then
    echo "$yes"
  else
    echo "$no"
  fi
}

if [[ "$RUN_PROBE" == "1" && -z "$STREAM_SUMMARY" ]]; then
  out="$(
    MODEL="$MODEL" \
    NUM_PREDICT="$NUM_PREDICT" \
    TEMPERATURE="$TEMPERATURE" \
    NUM_CTX="$NUM_CTX" \
    NUM_BATCH="$NUM_BATCH" \
    NUM_THREAD="$NUM_THREAD" \
    KEEP_ALIVE="$KEEP_ALIVE" \
    ROCBLAS_LAYER="$ROCBLAS_LAYER" \
    LOG_DIR="$LOG_DIR" \
    RAW_LOG_DIR="$RAW_LOG_DIR" \
    "$SCRIPT_DIR/g4-stream-phase-window-check.sh"
  )"
  STREAM_SUMMARY="$(printf '%s\n' "$out" | awk -F= '/^summary=/{print $2}' | tail -n 1)"
fi

if [[ -z "$STREAM_SUMMARY" || ! -f "$STREAM_SUMMARY" ]]; then
  echo "ERROR: STREAM_SUMMARY is missing or unreadable: $STREAM_SUMMARY" >&2
  exit 2
fi

stream_model="$(read_kv "$STREAM_SUMMARY" "model")"
stream_num_predict="$(read_kv "$STREAM_SUMMARY" "num_predict")"
stream_num_ctx="$(read_kv "$STREAM_SUMMARY" "num_ctx")"
stream_num_batch="$(read_kv "$STREAM_SUMMARY" "num_batch")"
stream_keep_alive="$(read_kv "$STREAM_SUMMARY" "keep_alive")"
phase_split_status_proxy="$(read_kv "$STREAM_SUMMARY" "phase_split_status_proxy")"
fallback_confirmed="$(read_kv "$STREAM_SUMMARY" "fallback_confirmed")"
dispatch_confirmed="$(read_kv "$STREAM_SUMMARY" "dispatch_confirmed")"
direct_dispatch="$(read_kv "$STREAM_SUMMARY" "direct_rocblas_or_tensile_dispatch")"
link_summary="$(read_kv "$STREAM_SUMMARY" "link_summary")"
strace_summary="$(read_kv "$STREAM_SUMMARY" "strace_summary")"

link_rocblas_layer=""
if [[ -n "$link_summary" && -f "$link_summary" ]]; then
  link_rocblas_layer="$(read_kv "$link_summary" "rocblas_layer")"
fi

decode_signature_label="decode_signature_not_observed"
if [[ "$phase_split_status_proxy" == "decode_signature_detected" ]]; then
  decode_signature_label="decode_signature_observed"
fi
fallback_label="$(bool_label "${fallback_confirmed:-0}" "fallback_confirmed" "fallback_not_confirmed")"
dispatch_label="$(bool_label "${dispatch_confirmed:-0}" "dispatch_confirmed" "dispatch_not_confirmed")"
direct_dispatch_label="$(bool_label "${direct_dispatch:-0}" "direct_dispatch_observed" "direct_dispatch_not_observed")"

shape_hit_total=0
shape_hit_note="shape_match_not_observed_or_out_of_target_set"
shape_trace_status="trace_unavailable"
rocblas_trace_log=""

if [[ -n "$strace_summary" && -f "$strace_summary" ]]; then
  rocblas_trace_log="$(read_kv "$strace_summary" "ROCBLAS_TRACE_LOG")"
fi

shape_lines=()
if [[ -n "$rocblas_trace_log" && -f "$rocblas_trace_log" ]]; then
  shape_trace_status="trace_available"
  IFS=',' read -r -a shapes <<< "$TARGET_SHAPES"
  for shape in "${shapes[@]}"; do
    shape="$(printf '%s' "$shape" | tr -d ' ')"
    m="$(printf '%s' "$shape" | cut -d'x' -f1)"
    n="$(printf '%s' "$shape" | cut -d'x' -f2)"
    k="$(printf '%s' "$shape" | cut -d'x' -f3)"
    if [[ -z "$m" || -z "$n" || -z "$k" ]]; then
      continue
    fi
    hits="$(grep -c ",${m},${n},${k}," "$rocblas_trace_log" || true)"
    shape_hit_total=$((shape_hit_total + hits))
    shape_key="$(printf '%s' "$shape" | tr 'x' '_' | tr -cd '0-9_')"
    shape_lines+=("shape_${shape_key}_hits=${hits}")
  done
  if (( shape_hit_total > 0 )); then
    shape_hit_note="shape_match_observed"
  fi
fi

anchor_scope_note="anchor_condition_limited_to_current_probe"
anchor_scope_expected="model=gpt-oss:latest,rocblas_layer=9,num_ctx=8192,num_predict=128,keep_alive=5m,lane_num_batch=512|1024"

anchor_scope_match=1
if [[ "$stream_model" != "gpt-oss:latest" || "${link_rocblas_layer:-}" != "9" ]]; then
  anchor_scope_match=0
fi

kernel_mapping_note="kernel-level causal mapping pending (catalog-read and dispatch evidence are not a strict 1:1 mapping yet)"
generalization_note="do_not_generalize_to_other_workloads_without_revalidation"

{
  echo "timestamp=$TS"
  echo "stream_summary=$STREAM_SUMMARY"
  echo "link_summary=$link_summary"
  echo "strace_summary=$strace_summary"
  echo "rocblas_trace_log=$rocblas_trace_log"
  echo
  echo "--- anchor scope ---"
  echo "anchor_scope_note=$anchor_scope_note"
  echo "anchor_scope_expected=$anchor_scope_expected"
  echo "anchor_scope_match=$anchor_scope_match"
  echo "anchor_model_observed=$stream_model"
  echo "anchor_rocblas_layer_observed=${link_rocblas_layer:-unknown}"
  echo "anchor_num_ctx_observed=$stream_num_ctx"
  echo "anchor_num_predict_observed=$stream_num_predict"
  echo "anchor_keep_alive_observed=$stream_keep_alive"
  echo "anchor_num_batch_observed=$stream_num_batch"
  echo
  echo "--- observation labels ---"
  echo "decode_signature_label=$decode_signature_label"
  echo "fallback_label=$fallback_label"
  echo "dispatch_label=$dispatch_label"
  echo "direct_dispatch_label=$direct_dispatch_label"
  echo "shape_match_note=$shape_hit_note"
  echo "shape_trace_status=$shape_trace_status"
  echo "target_shapes=$TARGET_SHAPES"
  echo "shape_hit_total=$shape_hit_total"
  for line in "${shape_lines[@]}"; do
    echo "$line"
  done
  echo
  echo "--- pending mapping ---"
  echo "kernel_mapping_note=$kernel_mapping_note"
  echo "generalization_note=$generalization_note"
} > "$OUT_SUMMARY"

echo "summary=$OUT_SUMMARY"
