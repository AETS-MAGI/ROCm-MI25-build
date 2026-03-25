#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SUMMARY_DIR="${SUMMARY_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"

BASELINE_SPLIT_SUMMARY="${BASELINE_SPLIT_SUMMARY:-${1:-}}"
SIDE_SPLIT_SUMMARY="${SIDE_SPLIT_SUMMARY:-${2:-}}"

if [[ -z "$BASELINE_SPLIT_SUMMARY" || -z "$SIDE_SPLIT_SUMMARY" ]]; then
  cat >&2 <<'USAGE'
Usage:
  summarize-k1-entry.sh <baseline_split_summary.txt> <side_split_summary.txt>

Or set:
  BASELINE_SPLIT_SUMMARY=/path/to/g4_prefill_decode_split_...txt
  SIDE_SPLIT_SUMMARY=/path/to/g4_prefill_decode_split_...txt
USAGE
  exit 1
fi

if [[ ! -f "$BASELINE_SPLIT_SUMMARY" ]]; then
  echo "ERROR: baseline split summary not found: $BASELINE_SPLIT_SUMMARY" >&2
  exit 2
fi
if [[ ! -f "$SIDE_SPLIT_SUMMARY" ]]; then
  echo "ERROR: side split summary not found: $SIDE_SPLIT_SUMMARY" >&2
  exit 3
fi

mkdir -p "$SUMMARY_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_TSV="$SUMMARY_DIR/k1_entry_lane_check_${TS}.tsv"
OUT_TXT="$SUMMARY_DIR/k1_entry_lane_check_${TS}.txt"

read_kv() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file"
}

extract_tool_path() {
  local output="$1"
  local key="$2"
  printf '%s\n' "$output" | awk -F= -v k="$key" '$1 == k { print $2; exit }'
}

candidate_value() {
  local tsv="$1"
  local key="$2"
  local col="$3"

  awk -F'\t' -v key="$key" -v col="$col" '
    NR == 1 { next }
    {
      k = $1
      if (key == "K1" && k ~ /_BBS_BH_/) {
        print $col; found = 1; exit
      }
      if (key == "K2" && k ~ /_HB_GB_/ && k !~ /_HSS_BH_GB_/) {
        print $col; found = 1; exit
      }
      if (key == "K3" && k ~ /_HSS_BH_GB_/) {
        print $col; found = 1; exit
      }
      if (key == "K4" && k ~ /_SB_/ && k ~ /_ISA900/) {
        print $col; found = 1; exit
      }
    }
    END {
      if (!found) print 0
    }
  ' "$tsv"
}

map_value() {
  local tsv="$1"
  local key="$2"

  awk -F'\t' -v key="$key" '
    NR == 1 { next }
    {
      k = $1
      if (key == "K1" && k ~ /_BBS_BH_/) {
        print $2; found = 1; exit
      }
      if (key == "K2" && k ~ /_HB_GB_/ && k !~ /_HSS_BH_GB_/) {
        print $2; found = 1; exit
      }
      if (key == "K3" && k ~ /_HSS_BH_GB_/) {
        print $2; found = 1; exit
      }
      if (key == "K4" && k ~ /_SB_/ && k ~ /_ISA900/) {
        print $2; found = 1; exit
      }
    }
    END {
      if (!found) print 0
    }
  ' "$tsv"
}

run_lane() {
  local lane="$1"
  local split_summary="$2"

  local prefill_rocprof full_rocprof
  prefill_rocprof="$(read_kv "$split_summary" "prefill_rocprof_summary")"
  full_rocprof="$(read_kv "$split_summary" "full_rocprof_summary")"

  if [[ -z "$prefill_rocprof" || ! -f "$prefill_rocprof" ]]; then
    echo "ERROR: $lane prefill_rocprof_summary missing: $prefill_rocprof" >&2
    exit 4
  fi
  if [[ -z "$full_rocprof" || ! -f "$full_rocprof" ]]; then
    echo "ERROR: $lane full_rocprof_summary missing: $full_rocprof" >&2
    exit 5
  fi

  local cand_out cand_summary cand_tsv
  cand_out="$("$SCRIPT_DIR/summarize-kernel-candidates.sh" "$prefill_rocprof" "$full_rocprof")"
  cand_summary="$(extract_tool_path "$cand_out" "summary")"
  cand_tsv="$(extract_tool_path "$cand_out" "tsv")"

  if [[ -z "$cand_summary" || -z "$cand_tsv" || ! -f "$cand_summary" || ! -f "$cand_tsv" ]]; then
    echo "ERROR: failed to produce candidate outputs for lane=$lane" >&2
    exit 6
  fi

  local map_out map_summary map_tsv
  map_out="$("$SCRIPT_DIR/map-kernel-candidates-to-hsaco.sh" "$cand_tsv")"
  map_summary="$(extract_tool_path "$map_out" "summary")"
  map_tsv="$(extract_tool_path "$map_out" "tsv")"

  if [[ -z "$map_summary" || -z "$map_tsv" || ! -f "$map_summary" || ! -f "$map_tsv" ]]; then
    echo "ERROR: failed to produce hsaco map outputs for lane=$lane" >&2
    exit 7
  fi

  local total_candidates matched_candidates hsaco_file_count
  total_candidates="$(read_kv "$map_summary" "total_candidates")"
  matched_candidates="$(read_kv "$map_summary" "matched_candidates")"
  hsaco_file_count="$(read_kv "$map_summary" "hsaco_file_count")"

  local k1_prefill k1_full k1_delta k1_match
  local k2_prefill k2_full k2_delta k2_match
  local k3_prefill k3_full k3_delta k3_match
  local k4_prefill k4_full k4_delta k4_match

  k1_prefill="$(candidate_value "$cand_tsv" "K1" 2)"
  k1_full="$(candidate_value "$cand_tsv" "K1" 3)"
  k1_delta="$(candidate_value "$cand_tsv" "K1" 4)"
  k1_match="$(map_value "$map_tsv" "K1")"

  k2_prefill="$(candidate_value "$cand_tsv" "K2" 2)"
  k2_full="$(candidate_value "$cand_tsv" "K2" 3)"
  k2_delta="$(candidate_value "$cand_tsv" "K2" 4)"
  k2_match="$(map_value "$map_tsv" "K2")"

  k3_prefill="$(candidate_value "$cand_tsv" "K3" 2)"
  k3_full="$(candidate_value "$cand_tsv" "K3" 3)"
  k3_delta="$(candidate_value "$cand_tsv" "K3" 4)"
  k3_match="$(map_value "$map_tsv" "K3")"

  k4_prefill="$(candidate_value "$cand_tsv" "K4" 2)"
  k4_full="$(candidate_value "$cand_tsv" "K4" 3)"
  k4_delta="$(candidate_value "$cand_tsv" "K4" 4)"
  k4_match="$(map_value "$map_tsv" "K4")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$lane" "$split_summary" "$cand_summary" "$cand_tsv" "$map_summary" "$map_tsv" \
    "${total_candidates:-0}" "${matched_candidates:-0}" "${hsaco_file_count:-0}" \
    "$k1_prefill" "$k1_full" "$k1_delta" "$k1_match" \
    "$k2_prefill" "$k2_full" "$k2_delta" "$k2_match" \
    "$k3_prefill" "$k3_full" "$k3_delta" "$k3_match" \
    "$k4_prefill" "$k4_full" "$k4_delta" "$k4_match" >> "$OUT_TSV"
}

printf '%s\n' "lane	split_summary	candidate_summary	candidate_tsv	map_summary	map_tsv	total_candidates	matched_candidates	hsaco_file_count	k1_prefill	k1_full	k1_delta	k1_match	k2_prefill	k2_full	k2_delta	k2_match	k3_prefill	k3_full	k3_delta	k3_match	k4_prefill	k4_full	k4_delta	k4_match" > "$OUT_TSV"

run_lane "baseline" "$BASELINE_SPLIT_SUMMARY"
run_lane "side" "$SIDE_SPLIT_SUMMARY"

{
  echo "timestamp=$TS"
  echo "baseline_split_summary=$BASELINE_SPLIT_SUMMARY"
  echo "side_split_summary=$SIDE_SPLIT_SUMMARY"
  echo "table=$OUT_TSV"
  echo
  echo "--- lane rows ---"
  cat "$OUT_TSV"
  echo
  echo "--- interpretation ---"
  awk -F'\t' '
    NR==1 { next }
    {
      lane=$1
      total=$7+0
      matched=$8+0
      k1f=$11+0
      k1m=$13+0
      k4m=$25+0
      printf("%s: total_candidates=%d matched=%d K1_full=%d K1_match=%d K4_match=%d\n", lane, total, matched, k1f, k1m, k4m)
    }
  ' "$OUT_TSV"
} > "$OUT_TXT"

echo "summary=$OUT_TXT"
echo "tsv=$OUT_TSV"
