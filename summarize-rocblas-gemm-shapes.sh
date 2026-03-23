#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"

TRACE_LOG="${TRACE_LOG:-${1:-}}"
if [[ -z "$TRACE_LOG" ]]; then
  TRACE_LOG="$(ls -1t "$RAW_LOG_DIR"/g4_rocblas_trace_*.log 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$TRACE_LOG" ]]; then
  # Backward-compat fallback for older in-repo layouts.
  TRACE_LOG="$(ls -1t "$LOG_DIR"/g4_rocblas_trace_*.log 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$TRACE_LOG" || ! -f "$TRACE_LOG" ]]; then
  echo "ERROR: trace log not found. Set TRACE_LOG or pass a file path." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
TRACE_BASENAME="$(basename "$TRACE_LOG" .log)"
OUT_TSV="$LOG_DIR/rocblas_gemm_shapes_${TRACE_BASENAME}_${TS}.tsv"
OUT_SUMMARY="$LOG_DIR/rocblas_gemm_shapes_${TRACE_BASENAME}_${TS}.txt"
TMP_TSV="$(mktemp)"

trim() {
  # shellcheck disable=SC2001
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

awk -F',' '
  BEGIN { OFS="\t" }
  function t(s) {
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    return s
  }
  function dtype(s) {
    s = t(s)
    if (s ~ /_r$/) {
      return s
    }
    return ""
  }
  function add_row(kind, api, ta, tb, m, n, k, at, bt, ct, dt, comp) {
    key = kind OFS api OFS ta OFS tb OFS m OFS n OFS k OFS at OFS bt OFS ct OFS dt OFS comp
    cnt[key]++
  }
  {
    api = t($1)
    if (api == "rocblas_gemm_ex" || api == "rocblas_gemm_batched_ex") {
      add_row("gemm", api, t($2), t($3), t($4), t($5), t($6), dtype($9), dtype($12), dtype($15), dtype($18), dtype($20))
    } else if (api == "rocblas_sgemm") {
      add_row("gemm", api, t($2), t($3), t($4), t($5), t($6), "f32_r", "f32_r", "f32_r", "f32_r", "f32_r")
    } else if (api == "rocblas_hgemm") {
      add_row("gemm", api, t($2), t($3), t($4), t($5), t($6), "f16_r", "f16_r", "f16_r", "f16_r", "f16_r")
    } else if (api == "rocblas_dgemm") {
      add_row("gemm", api, t($2), t($3), t($4), t($5), t($6), "f64_r", "f64_r", "f64_r", "f64_r", "f64_r")
    } else if (api == "rocblas_internal" && t($2) == "rocblas_gemm_tensile_backend") {
      add_row("internal", t($2), t($3), t($4), t($5), t($6), t($7), "", "", "", "", "")
    }
  }
  END {
    print "kind","api_or_backend","transA","transB","m","n","k","a_type","b_type","c_type","d_type","compute_type","count"
    for (k in cnt) {
      split(k, a, OFS)
      print a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9],a[10],a[11],a[12],cnt[k]
    }
  }
' "$TRACE_LOG" > "$TMP_TSV"

{
  head -n 1 "$TMP_TSV"
  tail -n +2 "$TMP_TSV" | sort -t$'\t' -k13,13nr -k1,1 -k2,2
} > "$OUT_TSV"

rm -f "$TMP_TSV"

total_lines="$(wc -l < "$TRACE_LOG" | tr -d ' ')"
handle_lines="$( (rg -n '^rocblas_create_handle' "$TRACE_LOG" || true) | wc -l | tr -d ' ' )"
gemm_lines="$( (rg -n '^rocblas_(gemm_ex|gemm_batched_ex|sgemm|hgemm|dgemm)' "$TRACE_LOG" || true) | wc -l | tr -d ' ' )"
internal_tensile_lines="$( (rg -n '^rocblas_internal,rocblas_gemm_tensile_backend' "$TRACE_LOG" || true) | wc -l | tr -d ' ' )"
top5="$(tail -n +2 "$OUT_TSV" | head -n 5)"

{
  echo "timestamp=$TS"
  echo "trace_log=$TRACE_LOG"
  echo "tsv=$OUT_TSV"
  echo "total_lines=$total_lines"
  echo "handle_lines=$handle_lines"
  echo "gemm_api_lines=$gemm_lines"
  echo "internal_tensile_lines=$internal_tensile_lines"
  echo
  echo "--- top_5_by_count ---"
  if [[ -n "$top5" ]]; then
    printf '%s\n' "$top5"
  else
    echo "none"
  fi
} > "$OUT_SUMMARY"

echo "summary=$OUT_SUMMARY"
echo "tsv=$OUT_TSV"
