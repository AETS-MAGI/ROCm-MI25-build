#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SUMMARY_DIR="${SUMMARY_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"

PREFILL_TRACE="${PREFILL_TRACE:-${1:-}}"
FULL_TRACE="${FULL_TRACE:-${2:-}}"

if [[ -z "$PREFILL_TRACE" || -z "$FULL_TRACE" ]]; then
  echo "Usage: $0 <prefill_rocblas_trace.log> <full_rocblas_trace.log>" >&2
  echo "Or set PREFILL_TRACE and FULL_TRACE environment variables." >&2
  exit 1
fi

if [[ ! -f "$PREFILL_TRACE" ]]; then
  echo "ERROR: prefill trace not found: $PREFILL_TRACE" >&2
  exit 2
fi
if [[ ! -f "$FULL_TRACE" ]]; then
  echo "ERROR: full trace not found: $FULL_TRACE" >&2
  exit 3
fi

mkdir -p "$SUMMARY_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
PREFILL_TAG="$(basename "$PREFILL_TRACE" .log)"
FULL_TAG="$(basename "$FULL_TRACE" .log)"
OUT_TSV="$SUMMARY_DIR/rocblas_shape_prefill_full_compare_${PREFILL_TAG}__${FULL_TAG}_${TS}.tsv"
OUT_TXT="$SUMMARY_DIR/rocblas_shape_prefill_full_compare_${PREFILL_TAG}__${FULL_TAG}_${TS}.txt"

awk -F',' '
  BEGIN { OFS="\t" }
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  function add(prefix, m, n, k) {
    key = m "x" n "x" k
    cnt[prefix, key]++
    keys[key] = 1
    total[prefix]++
  }
  FNR == NR {
    api = trim($1)
    if (api ~ /^rocblas_(gemm_ex|gemm_batched_ex|sgemm|hgemm|dgemm)$/) {
      add("prefill", trim($4), trim($5), trim($6))
    }
    next
  }
  {
    api = trim($1)
    if (api ~ /^rocblas_(gemm_ex|gemm_batched_ex|sgemm|hgemm|dgemm)$/) {
      add("full", trim($4), trim($5), trim($6))
    }
  }
  END {
    print "shape","prefill_count","full_count","delta","delta_positive","prefill_ratio_pct","full_ratio_pct"
    for (k in keys) {
      p = (("prefill", k) in cnt ? cnt["prefill", k] : 0)
      f = (("full", k) in cnt ? cnt["full", k] : 0)
      d = f - p
      dp = (d > 0 ? d : 0)
      pr = (total["prefill"] > 0 ? (100.0 * p / total["prefill"]) : 0.0)
      fr = (total["full"] > 0 ? (100.0 * f / total["full"]) : 0.0)
      printf "%s\t%d\t%d\t%d\t%d\t%.2f\t%.2f\n", k, p, f, d, dp, pr, fr
    }
    printf "__TOTAL__\t%d\t%d\t%d\t%d\t100.00\t100.00\n",
      total["prefill"] + 0, total["full"] + 0,
      (total["full"] + 0) - (total["prefill"] + 0),
      (((total["full"] + 0) - (total["prefill"] + 0)) > 0 ? ((total["full"] + 0) - (total["prefill"] + 0)) : 0)
  }
' "$PREFILL_TRACE" "$FULL_TRACE" \
  | awk 'NR>1 {print}' \
  | sort -t$'\t' -k5,5nr -k4,4nr -k3,3nr > "$OUT_TSV.tmp"

{
  echo -e "shape\tprefill_count\tfull_count\tdelta\tdelta_positive\tprefill_ratio_pct\tfull_ratio_pct"
  cat "$OUT_TSV.tmp"
} > "$OUT_TSV"
rm -f "$OUT_TSV.tmp"

TOTAL_PREFILL="$(awk -F'\t' '$1=="__TOTAL__" {print $2}' "$OUT_TSV")"
TOTAL_FULL="$(awk -F'\t' '$1=="__TOTAL__" {print $3}' "$OUT_TSV")"
TOTAL_DELTA="$(awk -F'\t' '$1=="__TOTAL__" {print $4}' "$OUT_TSV")"

TOP_POS="$(awk -F'\t' 'NR>1 && $1!="__TOTAL__" {print}' "$OUT_TSV" | sort -t$'\t' -k5,5nr -k4,4nr -k3,3nr | head -n 15)"
TOP_PREFILL="$(awk -F'\t' 'NR>1 && $1!="__TOTAL__" {print}' "$OUT_TSV" | sort -t$'\t' -k2,2nr | head -n 15)"
TOP_FULL="$(awk -F'\t' 'NR>1 && $1!="__TOTAL__" {print}' "$OUT_TSV" | sort -t$'\t' -k3,3nr | head -n 15)"

{
  echo "timestamp=$TS"
  echo "prefill_trace=$PREFILL_TRACE"
  echo "full_trace=$FULL_TRACE"
  echo "tsv=$OUT_TSV"
  echo "total_prefill=$TOTAL_PREFILL"
  echo "total_full=$TOTAL_FULL"
  echo "total_delta=$TOTAL_DELTA"
  echo
  echo "--- top_delta_positive ---"
  if [[ -n "$TOP_POS" ]]; then
    printf '%s\n' "$TOP_POS"
  else
    echo "none"
  fi
  echo
  echo "--- top_prefill_count ---"
  if [[ -n "$TOP_PREFILL" ]]; then
    printf '%s\n' "$TOP_PREFILL"
  else
    echo "none"
  fi
  echo
  echo "--- top_full_count ---"
  if [[ -n "$TOP_FULL" ]]; then
    printf '%s\n' "$TOP_FULL"
  else
    echo "none"
  fi
} > "$OUT_TXT"

echo "summary=$OUT_TXT"
echo "tsv=$OUT_TSV"
