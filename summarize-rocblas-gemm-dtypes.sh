#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
SUMMARY_DIR="${SUMMARY_DIR:-$RAW_LOG_DIR/summaries}"
REPO_LOG_DIR="${REPO_LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"

INPUT_TSV="${INPUT_TSV:-${1:-}}"
if [[ -z "$INPUT_TSV" ]]; then
  INPUT_TSV="$(ls -1t "$RAW_LOG_DIR"/rocblas_gemm_shapes_*.tsv 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$INPUT_TSV" ]]; then
  INPUT_TSV="$(ls -1t "$SUMMARY_DIR"/rocblas_gemm_shapes_*.tsv 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$INPUT_TSV" ]]; then
  INPUT_TSV="$(ls -1t "$REPO_LOG_DIR"/rocblas_gemm_shapes_*.tsv 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$INPUT_TSV" || ! -f "$INPUT_TSV" ]]; then
  echo "ERROR: rocBLAS gemm-shapes TSV not found. Pass INPUT_TSV or place files under RAW/SUMMARY dirs." >&2
  exit 1
fi

mkdir -p "$SUMMARY_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
BASE="$(basename "$INPUT_TSV" .tsv)"
OUT_TSV="$SUMMARY_DIR/rocblas_gemm_dtype_summary_${BASE}_${TS}.tsv"
OUT_TXT="$SUMMARY_DIR/rocblas_gemm_dtype_summary_${BASE}_${TS}.txt"
TMP_TSV="$(mktemp)"

awk -F'\t' '
  BEGIN { OFS="\t" }
  function trim(s) {
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    return s
  }
  NR == 1 { next }
  $1 == "gemm" {
    api = trim($2)
    m = trim($5); n = trim($6); k = trim($7)
    at = trim($8); bt = trim($9); ct = trim($10); dt = trim($11); comp = trim($12)
    cnt = ($13 + 0)
    sig = at "|" bt "|" ct "|" dt "|" comp
    shp = m "x" n "x" k

    total += cnt
    sig_cnt[sig] += cnt
    api_cnt[api] += cnt
    shape_cnt[shp] += cnt

    if (sig ~ /i8_r|i32_r|int8|int32/) {
      int8_like += cnt
    } else {
      non_dot4_like += cnt
    }
  }
  END {
    if (total == 0) {
      total = 1
    }
    non_dot4_like += 0
    int8_like += 0
    print "section","key","count","ratio_pct","note"
    print "classification","total_gemm",total,"100.00","gemm-only rows from input tsv"
    print "classification","non_dot4_like",non_dot4_like,sprintf("%.2f",(non_dot4_like*100.0)/total),"signature has no int8/i32 token"
    print "classification","int8_or_i32_like",int8_like,sprintf("%.2f",(int8_like*100.0)/total),"signature contains i8/i32 token"

    for (k in sig_cnt) {
      print "dtype_signature",k,sig_cnt[k],sprintf("%.2f",(sig_cnt[k]*100.0)/total),""
    }
    for (k in api_cnt) {
      print "api",k,api_cnt[k],sprintf("%.2f",(api_cnt[k]*100.0)/total),""
    }
    for (k in shape_cnt) {
      print "shape",k,shape_cnt[k],sprintf("%.2f",(shape_cnt[k]*100.0)/total),""
    }
  }
' "$INPUT_TSV" > "$TMP_TSV"

{
  head -n 1 "$TMP_TSV"
  tail -n +2 "$TMP_TSV" | sort -t$'\t' -k1,1 -k3,3nr -k2,2
} > "$OUT_TSV"

rm -f "$TMP_TSV"

TOTAL="$(awk -F'\t' '$1=="classification" && $2=="total_gemm" {print $3}' "$OUT_TSV" | head -n 1)"
NON_DOT4="$(awk -F'\t' '$1=="classification" && $2=="non_dot4_like" {print $3}' "$OUT_TSV" | head -n 1)"
INT8="$(awk -F'\t' '$1=="classification" && $2=="int8_or_i32_like" {print $3}' "$OUT_TSV" | head -n 1)"

TOP_DTYPE="$(awk -F'\t' '$1=="dtype_signature" {print $2"\t"$3"\t"$4"%"}' "$OUT_TSV" | head -n 5)"
TOP_API="$(awk -F'\t' '$1=="api" {print $2"\t"$3"\t"$4"%"}' "$OUT_TSV" | head -n 5)"
TOP_SHAPE="$(awk -F'\t' '$1=="shape" {print $2"\t"$3"\t"$4"%"}' "$OUT_TSV" | head -n 10)"

{
  echo "timestamp=$TS"
  echo "input_tsv=$INPUT_TSV"
  echo "summary_tsv=$OUT_TSV"
  echo "total_gemm=$TOTAL"
  echo "non_dot4_like=$NON_DOT4"
  echo "int8_or_i32_like=$INT8"
  echo
  echo "--- top_dtype_signature ---"
  if [[ -n "$TOP_DTYPE" ]]; then
    printf '%s\n' "$TOP_DTYPE"
  else
    echo "none"
  fi
  echo
  echo "--- top_api ---"
  if [[ -n "$TOP_API" ]]; then
    printf '%s\n' "$TOP_API"
  else
    echo "none"
  fi
  echo
  echo "--- top_shape ---"
  if [[ -n "$TOP_SHAPE" ]]; then
    printf '%s\n' "$TOP_SHAPE"
  else
    echo "none"
  fi
} > "$OUT_TXT"

echo "summary=$OUT_TXT"
echo "tsv=$OUT_TSV"
