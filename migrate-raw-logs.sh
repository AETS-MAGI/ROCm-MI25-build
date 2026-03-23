#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

SRC_DIR="${SRC_DIR:-$SCRIPT_DIR/vega_path_check_logs}"
DST_DIR="${DST_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
SUMMARY_DIR="${SUMMARY_DIR:-$SCRIPT_DIR/vega_path_check_logs}"

# copy | move
MODE="${MODE:-copy}"

mkdir -p "$SRC_DIR" "$DST_DIR" "$SUMMARY_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MANIFEST="$SUMMARY_DIR/raw_log_migrate_manifest_${TS}.tsv"
SUMMARY="$SUMMARY_DIR/raw_log_migrate_summary_${TS}.txt"

printf "timestamp\tstatus\tsrc_path\tdst_path\n" > "$MANIFEST"

count_total=0
count_done=0
count_skipped=0
count_failed=0

is_raw_file() {
  local name="$1"
  case "$name" in
    *.log|*.log.*|*.json|*.csv) return 0 ;;
    g4_strace_openat_*|g4_rocblas_trace_*|g4_rocblas_bench_*|g4_rocblas_profile_*|g4_serve_stdout_*|g4_serve_stderr_*|g4_generate_*|rocprofv3_serve_stdout_*|rocprofv3_serve_stderr_*|rocprofv3_generate_*) return 0 ;;
  esac
  return 1
}

while IFS= read -r -d '' src; do
  base="$(basename "$src")"
  if ! is_raw_file "$base"; then
    continue
  fi
  count_total=$((count_total + 1))
  dst="$DST_DIR/$base"
  if [[ -e "$dst" ]]; then
    printf "%s\tskip_exists\t%s\t%s\n" "$TS" "$src" "$dst" >> "$MANIFEST"
    count_skipped=$((count_skipped + 1))
    continue
  fi

  if [[ "$MODE" == "move" ]]; then
    if mv "$src" "$dst"; then
      printf "%s\tmoved\t%s\t%s\n" "$TS" "$src" "$dst" >> "$MANIFEST"
      count_done=$((count_done + 1))
    else
      printf "%s\tfailed\t%s\t%s\n" "$TS" "$src" "$dst" >> "$MANIFEST"
      count_failed=$((count_failed + 1))
    fi
  else
    if cp -a "$src" "$dst"; then
      printf "%s\tcopied\t%s\t%s\n" "$TS" "$src" "$dst" >> "$MANIFEST"
      count_done=$((count_done + 1))
    else
      printf "%s\tfailed\t%s\t%s\n" "$TS" "$src" "$dst" >> "$MANIFEST"
      count_failed=$((count_failed + 1))
    fi
  fi
done < <(find "$SRC_DIR" -maxdepth 1 -type f -print0)

# rocprofv3 per-run directories are usually heavy raw artifacts.
while IFS= read -r -d '' src_dir; do
  dir_name="$(basename "$src_dir")"
  dst_dir="$DST_DIR/$dir_name"
  count_total=$((count_total + 1))

  if [[ -e "$dst_dir" ]]; then
    printf "%s\tskip_exists\t%s\t%s\n" "$TS" "$src_dir" "$dst_dir" >> "$MANIFEST"
    count_skipped=$((count_skipped + 1))
    continue
  fi

  if [[ "$MODE" == "move" ]]; then
    if mv "$src_dir" "$dst_dir"; then
      printf "%s\tmoved_dir\t%s\t%s\n" "$TS" "$src_dir" "$dst_dir" >> "$MANIFEST"
      count_done=$((count_done + 1))
    else
      printf "%s\tfailed\t%s\t%s\n" "$TS" "$src_dir" "$dst_dir" >> "$MANIFEST"
      count_failed=$((count_failed + 1))
    fi
  else
    if cp -a "$src_dir" "$dst_dir"; then
      printf "%s\tcopied_dir\t%s\t%s\n" "$TS" "$src_dir" "$dst_dir" >> "$MANIFEST"
      count_done=$((count_done + 1))
    else
      printf "%s\tfailed\t%s\t%s\n" "$TS" "$src_dir" "$dst_dir" >> "$MANIFEST"
      count_failed=$((count_failed + 1))
    fi
  fi
done < <(find "$SRC_DIR" -maxdepth 1 -type d -name 'rocprofv3_probe_*' -print0)

{
  echo "timestamp=$TS"
  echo "src_dir=$SRC_DIR"
  echo "dst_dir=$DST_DIR"
  echo "mode=$MODE"
  echo "manifest=$MANIFEST"
  echo
  echo "--- counts ---"
  echo "total_candidates=$count_total"
  echo "done=$count_done"
  echo "skipped_exists=$count_skipped"
  echo "failed=$count_failed"
} > "$SUMMARY"

echo "summary=$SUMMARY"
echo "manifest=$MANIFEST"
