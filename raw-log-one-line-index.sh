#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
SUMMARY_DIR="${SUMMARY_DIR:-$RAW_LOG_DIR/summaries}"
LABEL_RAW="${1:-dispatch-boundary}"
LABEL="${LABEL_RAW//[^a-zA-Z0-9_-]/_}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="${2:-$SUMMARY_DIR/raw_log_one_line_index_${LABEL}_${TS}.tsv}"

mkdir -p "$SUMMARY_DIR"

collect_latest() {
  local pattern="$1"
  local latest=""
  if compgen -G "$RAW_LOG_DIR/$pattern" >/dev/null; then
    latest="$(ls -1t "$RAW_LOG_DIR"/$pattern 2>/dev/null | head -n 1 || true)"
  fi
  printf '%s' "$latest"
}

count_matches() {
  local pattern="$1"
  local cnt=0
  if compgen -G "$RAW_LOG_DIR/$pattern" >/dev/null; then
    cnt="$(ls -1 "$RAW_LOG_DIR"/$pattern 2>/dev/null | wc -l | tr -d ' ')"
  fi
  printf '%s' "$cnt"
}

mtime_or_dash() {
  local path="$1"
  if [[ -n "$path" && -e "$path" ]]; then
    date -r "$path" +%Y-%m-%dT%H:%M:%S%z
  else
    printf '%s' '-'
  fi
}

printf 'label\tcategory\tpattern\tcount\tlatest_file\tlatest_mtime\n' > "$OUT"

# Keep this list short and stable to remain one-line index friendly.
PATTERN_ROWS=(
  "strace_openat|g4_strace_openat_*.log*"
  "rocblas_trace|g4_rocblas_trace_*.log"
  "rocblas_bench|g4_rocblas_bench_*.log"
  "rocblas_profile|g4_rocblas_profile_*.log"
  "stream_jsonl|g4_stream_*.jsonl"
  "serve_stdout|g4_serve_stdout_*.log"
  "serve_stderr|g4_serve_stderr_*.log"
  "generate_json|g4_generate_*.json"
  "rocprof_probe_dir|rocprofv3_probe_*"
)

for row in "${PATTERN_ROWS[@]}"; do
  category="${row%%|*}"
  pattern="${row#*|}"

  count="$(count_matches "$pattern")"
  latest="$(collect_latest "$pattern")"
  latest_mtime="$(mtime_or_dash "$latest")"
  latest_rel="-"
  if [[ -n "$latest" ]]; then
    latest_rel="${latest#"$RAW_LOG_DIR"/}"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LABEL" "$category" "$pattern" "$count" "$latest_rel" "$latest_mtime" >> "$OUT"
done

echo "index=$OUT"
