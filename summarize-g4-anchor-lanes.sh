#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RAW_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
SUM_DIR="${SUMMARY_DIR:-$RAW_DIR/summaries}"
MODEL_TAG="${MODEL_TAG:-gpt-oss_latest}"
TS="$(date +%Y%m%d_%H%M%S)"

mkdir -p "$SUM_DIR"

pick_latest_anchor_summary() {
  local batch="$1"
  local best_file=""
  local best_ok=-1
  local best_mtime=0
  for f in "$RAW_DIR"/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_*.txt; do
    [[ -f "$f" ]] || continue
    if grep -q "^num_batch_list=${batch}$" "$f"; then
      local ok
      ok="$(grep -E '^ok_cases=' "$f" | tail -n 1 | cut -d'=' -f2-)"
      [[ "$ok" =~ ^[0-9]+$ ]] || ok=0
      local mtime
      mtime="$(stat -c '%Y' "$f" 2>/dev/null || echo 0)"
      if (( ok > best_ok )); then
        best_ok="$ok"
        best_mtime="$mtime"
        best_file="$f"
      elif (( ok == best_ok && mtime > best_mtime )); then
        best_mtime="$mtime"
        best_file="$f"
      fi
    fi
  done
  printf '%s' "$best_file"
}

extract_kv() {
  local key="$1"
  local file="$2"
  grep -E "^${key}=" "$file" | tail -n 1 | cut -d'=' -f2-
}

extract_shape_total() {
  local shape="$1"
  local file="$2"
  grep -E "^shape_${shape}=" "$file" | tail -n 1 | cut -d'=' -f2-
}

BASE_SUMMARY="${BASELINE_SUMMARY:-$(pick_latest_anchor_summary 512)}"
SIDE_SUMMARY="${SIDE_SUMMARY:-$(pick_latest_anchor_summary 1024)}"
STREAM_COMPARE="${STREAM_COMPARE:-$SUM_DIR/g4_stream_phase_window_batch_compare_${MODEL_TAG}_20260324_123206.tsv}"

if [[ -z "$BASE_SUMMARY" || ! -f "$BASE_SUMMARY" ]]; then
  echo "ERROR: baseline summary not found. Set BASELINE_SUMMARY explicitly." >&2
  exit 2
fi
if [[ -z "$SIDE_SUMMARY" || ! -f "$SIDE_SUMMARY" ]]; then
  echo "ERROR: side summary not found. Set SIDE_SUMMARY explicitly." >&2
  exit 2
fi
if [[ ! -f "$STREAM_COMPARE" ]]; then
  echo "ERROR: stream compare TSV not found: $STREAM_COMPARE" >&2
  exit 2
fi

OUT_TSV="$SUM_DIR/g4_anchor_lane_status_${MODEL_TAG}_${TS}.tsv"
OUT_TXT="$SUM_DIR/g4_anchor_lane_status_${MODEL_TAG}_${TS}.txt"

base_ok="$(extract_kv ok_cases "$BASE_SUMMARY")"
base_direct="$(extract_kv direct_hits "$BASE_SUMMARY")"
base_s1="$(extract_shape_total 512x512x2880 "$BASE_SUMMARY")"
base_s2="$(extract_shape_total 2880x512x4096 "$BASE_SUMMARY")"
base_s3="$(extract_shape_total 4096x512x2880 "$BASE_SUMMARY")"

side_ok="$(extract_kv ok_cases "$SIDE_SUMMARY")"
side_direct="$(extract_kv direct_hits "$SIDE_SUMMARY")"
side_s1="$(extract_shape_total 512x1024x2880 "$SIDE_SUMMARY")"
side_s2="$(extract_shape_total 2880x1024x4096 "$SIDE_SUMMARY")"
side_s3="$(extract_shape_total 4096x1024x2880 "$SIDE_SUMMARY")"

stream_rows="$(awk 'NR>1{c++} END{print c+0}' "$STREAM_COMPARE")"
stream_all_direct="$(awk -F'\t' 'NR>1 && $16==1 && $17==1 && $18==1 {c++} END{print c+0}' "$STREAM_COMPARE")"
stream_all_decode_sig="$(awk -F'\t' 'NR>1 && $4=="decode_signature_detected" && $5=="decode_signature_detected" {c++} END{print c+0}' "$STREAM_COMPARE")"

printf 'lane\tmodel\tnum_batch\tok_cases\tdirect_hits\tshape_a\tshape_b\tshape_c\n' > "$OUT_TSV"
printf 'baseline\tgpt-oss:latest\t512\t%s\t%s\t%s\t%s\t%s\n' \
  "$base_ok" "$base_direct" "$base_s1" "$base_s2" "$base_s3" >> "$OUT_TSV"
printf 'side\tgpt-oss:latest\t1024\t%s\t%s\t%s\t%s\t%s\n' \
  "$side_ok" "$side_direct" "$side_s1" "$side_s2" "$side_s3" >> "$OUT_TSV"

{
  echo "timestamp=$TS"
  echo "model=gpt-oss:latest"
  echo "baseline_summary=$BASE_SUMMARY"
  echo "side_summary=$SIDE_SUMMARY"
  echo "stream_compare_tsv=$STREAM_COMPARE"
  echo
  echo "[lane status]"
  echo "baseline: ok_cases=$base_ok direct_hits=$base_direct shapes=($base_s1,$base_s2,$base_s3)"
  echo "side: ok_cases=$side_ok direct_hits=$side_direct shapes=($side_s1,$side_s2,$side_s3)"
  echo
  echo "[stream phase-window consistency]"
  echo "rows=$stream_rows"
  echo "all_direct_gate_rows=$stream_all_direct"
  echo "all_decode_signature_rows=$stream_all_decode_sig"
  echo
  echo "[interpretation]"
  if [[ "$base_ok" == "$base_direct" && "$side_ok" == "$side_direct" ]]; then
    echo "direct dispatch is stable in both lanes under anchor conditions."
  else
    echo "direct dispatch stability is not complete; inspect source summaries."
  fi
  if [[ "$stream_rows" == "$stream_all_decode_sig" && "$stream_rows" == "$stream_all_direct" ]]; then
    echo "stream window lane keeps decode_signature_detected with direct/fallback/dispatch gates for all rows."
  else
    echo "stream window lane has mixed gate/signature rows; inspect compare TSV."
  fi
  echo
  echo "status_tsv=$OUT_TSV"
} > "$OUT_TXT"

echo "summary=$OUT_TXT"
echo "table=$OUT_TSV"
