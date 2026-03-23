#!/usr/bin/env bash

set -euo pipefail

# Summarize fallback open timing from strace(openat/openat2) logs.
# Works with g4-fallback-strace-check.sh outputs (especially with STRACE_TIMESTAMP=1).
#
# Usage:
#   summarize-fallback-phases.sh [glob-pattern]
#
# Example:
#   summarize-fallback-phases.sh "/home/$USER/ROCm-project/vega_path_check_logs_raw/g4_strace_openat_tinyllama_latest_20260324_014707.log.*"
#
# Output columns (TSV):
# file dat_count dat_first_line dat_last_line dat_first_time dat_last_time dat_span_s hsaco_count hsaco_first_line hsaco_last_line hsaco_first_time hsaco_last_time hsaco_span_s

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
DEFAULT_PATTERN="$RAW_LOG_DIR/g4_strace_openat_*.log.*"
PATTERN="${1:-$DEFAULT_PATTERN}"
INCLUDE_ZERO="${INCLUDE_ZERO:-0}"

shopt -s nullglob
files=( $PATTERN )
shopt -u nullglob

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "ERROR: no files matched pattern: $PATTERN" >&2
  exit 1
fi

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "file" \
  "dat_count" "dat_first_line" "dat_last_line" "dat_first_time" "dat_last_time" "dat_span_s" \
  "hsaco_count" "hsaco_first_line" "hsaco_last_line" "hsaco_first_time" "hsaco_last_time" "hsaco_span_s"

for f in "${files[@]}"; do
  awk '
    function parse_time_secs(line,    t, a) {
      if (match(line, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+/)) {
        t = substr(line, RSTART, RLENGTH)
        split(t, a, ":")
        return (a[1] + 0) * 3600 + (a[2] + 0) * 60 + (a[3] + 0)
      }
      return -1
    }
    function parse_time_text(line,    t) {
      if (match(line, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+/)) {
        t = substr(line, RSTART, RLENGTH)
        return t
      }
      return "n/a"
    }
    BEGIN {
      dat_count = 0
      dat_first_line = 0
      dat_last_line = 0
      dat_first_secs = -1
      dat_last_secs = -1
      dat_first_text = "n/a"
      dat_last_text = "n/a"

      hs_count = 0
      hs_first_line = 0
      hs_last_line = 0
      hs_first_secs = -1
      hs_last_secs = -1
      hs_first_text = "n/a"
      hs_last_text = "n/a"
    }
    {
      if ($0 ~ /TensileLibrary_.*_fallback\.dat/) {
        dat_count++
        if (dat_first_line == 0) {
          dat_first_line = NR
          dat_first_secs = parse_time_secs($0)
          dat_first_text = parse_time_text($0)
        }
        dat_last_line = NR
        dat_last_secs = parse_time_secs($0)
        dat_last_text = parse_time_text($0)
      }
      if ($0 ~ /TensileLibrary_.*_fallback_gfx900\.hsaco/) {
        hs_count++
        if (hs_first_line == 0) {
          hs_first_line = NR
          hs_first_secs = parse_time_secs($0)
          hs_first_text = parse_time_text($0)
        }
        hs_last_line = NR
        hs_last_secs = parse_time_secs($0)
        hs_last_text = parse_time_text($0)
      }
    }
    END {
      dat_span = "n/a"
      hs_span = "n/a"
      if (dat_count > 0 && dat_first_secs >= 0 && dat_last_secs >= 0) {
        dat_span = sprintf("%.6f", dat_last_secs - dat_first_secs)
      }
      if (hs_count > 0 && hs_first_secs >= 0 && hs_last_secs >= 0) {
        hs_span = sprintf("%.6f", hs_last_secs - hs_first_secs)
      }

      if (include_zero == 1 || dat_count > 0 || hs_count > 0) {
        printf("%s\t%d\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s\n",
               file,
               dat_count, dat_first_line, dat_last_line, dat_first_text, dat_last_text, dat_span,
               hs_count, hs_first_line, hs_last_line, hs_first_text, hs_last_text, hs_span)
      }
    }
  ' include_zero="$INCLUDE_ZERO" file="$f" "$f"
done | sort
