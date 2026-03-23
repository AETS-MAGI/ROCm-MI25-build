#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
SUMMARY_DIR="${SUMMARY_DIR:-$SCRIPT_DIR/vega_path_check_logs}"

# 1: keep original raw files after writing .gz
# 0: replace original raw files with .gz
KEEP_ORIGINAL="${KEEP_ORIGINAL:-1}"
# Compress only files older than this many days when >0.
OLDER_THAN_DAYS="${OLDER_THAN_DAYS:-0}"

mkdir -p "$RAW_LOG_DIR" "$SUMMARY_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MANIFEST="$SUMMARY_DIR/raw_log_compress_manifest_${TS}.tsv"
SUMMARY="$SUMMARY_DIR/raw_log_compress_summary_${TS}.txt"

printf "timestamp\tstatus\traw_path\traw_bytes\tgz_path\tgz_bytes\n" > "$MANIFEST"

count_total=0
count_compressed=0
count_replaced=0
count_skipped_exists=0
count_failed=0

find_args=(
  "$RAW_LOG_DIR"
  -type f
  ! -name '*.gz'
)
if [[ "$OLDER_THAN_DAYS" =~ ^[0-9]+$ ]] && (( OLDER_THAN_DAYS > 0 )); then
  find_args+=( -mtime "+${OLDER_THAN_DAYS}" )
fi

while IFS= read -r -d '' raw; do
  count_total=$((count_total + 1))
  raw_bytes="$(stat -c%s "$raw" 2>/dev/null || echo 0)"
  gz="${raw}.gz"

  if [[ -f "$gz" ]]; then
    gz_bytes="$(stat -c%s "$gz" 2>/dev/null || echo 0)"
    if [[ "$KEEP_ORIGINAL" == "0" ]]; then
      rm -f "$raw"
      printf "%s\treplaced_from_existing_gz\t%s\t%s\t%s\t%s\n" "$TS" "$raw" "$raw_bytes" "$gz" "$gz_bytes" >> "$MANIFEST"
      count_replaced=$((count_replaced + 1))
    else
      printf "%s\tskip_exists\t%s\t%s\t%s\t%s\n" "$TS" "$raw" "$raw_bytes" "$gz" "$gz_bytes" >> "$MANIFEST"
      count_skipped_exists=$((count_skipped_exists + 1))
    fi
    continue
  fi

  if gzip -n -c "$raw" > "$gz"; then
    gz_bytes="$(stat -c%s "$gz" 2>/dev/null || echo 0)"
    if [[ "$KEEP_ORIGINAL" == "0" ]]; then
      rm -f "$raw"
      printf "%s\tcompressed_replaced\t%s\t%s\t%s\t%s\n" "$TS" "$raw" "$raw_bytes" "$gz" "$gz_bytes" >> "$MANIFEST"
      count_replaced=$((count_replaced + 1))
    else
      printf "%s\tcompressed_kept\t%s\t%s\t%s\t%s\n" "$TS" "$raw" "$raw_bytes" "$gz" "$gz_bytes" >> "$MANIFEST"
    fi
    count_compressed=$((count_compressed + 1))
  else
    rm -f "$gz" || true
    printf "%s\tfailed\t%s\t%s\t%s\t0\n" "$TS" "$raw" "$raw_bytes" "$gz" >> "$MANIFEST"
    count_failed=$((count_failed + 1))
  fi
done < <(find "${find_args[@]}" -print0)

{
  echo "timestamp=$TS"
  echo "raw_log_dir=$RAW_LOG_DIR"
  echo "summary_dir=$SUMMARY_DIR"
  echo "keep_original=$KEEP_ORIGINAL"
  echo "older_than_days=$OLDER_THAN_DAYS"
  echo "manifest=$MANIFEST"
  echo
  echo "--- counts ---"
  echo "total_candidates=$count_total"
  echo "compressed=$count_compressed"
  echo "replaced=$count_replaced"
  echo "skipped_exists=$count_skipped_exists"
  echo "failed=$count_failed"
} > "$SUMMARY"

echo "summary=$SUMMARY"
echo "manifest=$MANIFEST"
