#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SUMMARY_DIR="${SUMMARY_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"

MAP_TSV="${MAP_TSV:-${1:-}}"

if [[ -z "$MAP_TSV" ]]; then
  cat >&2 <<'USAGE'
Usage:
  extract-hsaco-targets.sh <hsaco_candidate_map.tsv>

Or set:
  MAP_TSV=/path/to/hsaco_candidate_map_*.tsv
USAGE
  exit 1
fi

if [[ ! -f "$MAP_TSV" ]]; then
  echo "ERROR: map TSV not found: $MAP_TSV" >&2
  exit 2
fi

mkdir -p "$SUMMARY_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MAP_TAG="$(basename "$MAP_TSV" .tsv)"
OUT_DIR="$SUMMARY_DIR/hsaco_targets_${MAP_TAG}_${TS}"
MANIFEST="$SUMMARY_DIR/hsaco_targets_${MAP_TAG}_${TS}.txt"

mkdir -p "$OUT_DIR"

copied=0
{
  echo "map_tsv=$MAP_TSV"
  echo "output_dir=$OUT_DIR"
  echo "timestamp=$TS"
  echo
  echo "--- copied files ---"
} > "$MANIFEST"

while IFS=$'\t' read -r kernel_name match_count hsaco_files; do
  [[ "$kernel_name" == "kernel_name" ]] && continue
  [[ -z "${match_count:-}" ]] && continue
  if ! [[ "$match_count" =~ ^[0-9]+$ ]]; then
    continue
  fi
  if (( match_count <= 0 )); then
    continue
  fi
  IFS=';' read -r -a files <<< "${hsaco_files:-}"
  for src in "${files[@]}"; do
    [[ -z "$src" ]] && continue
    if [[ ! -f "$src" ]]; then
      echo "WARN: missing source hsaco: $src" >> "$MANIFEST"
      continue
    fi
    dst="$OUT_DIR/$(basename "$src")"
    cp -f "$src" "$dst"
    sha="$(sha256sum "$dst" | awk '{print $1}')"
    size="$(stat -c '%s' "$dst")"
    printf 'kernel=%s\nsrc=%s\ndst=%s\nsha256=%s\nsize_bytes=%s\n\n' \
      "$kernel_name" "$src" "$dst" "$sha" "$size" >> "$MANIFEST"
    copied=$((copied + 1))
  done
done < "$MAP_TSV"

{
  echo "--- summary ---"
  echo "copied_file_count=$copied"
} >> "$MANIFEST"

echo "manifest=$MANIFEST"
echo "output_dir=$OUT_DIR"
