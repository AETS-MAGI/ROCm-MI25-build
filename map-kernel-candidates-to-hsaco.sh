#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SUMMARY_DIR="${SUMMARY_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"
ROCBLAS_TENSILE_LIBPATH_DEFAULT="$WORKSPACE_ROOT/ROCm-repos_AETS/rocBLAS/build-mi25-gfx900/release/rocblas-install/lib/rocblas/library"

CANDIDATE_TSV="${CANDIDATE_TSV:-${1:-}}"
LIB_DIR="${ROCBLAS_TENSILE_LIBPATH:-${2:-$ROCBLAS_TENSILE_LIBPATH_DEFAULT}}"

if [[ -z "$CANDIDATE_TSV" ]]; then
  cat >&2 <<'USAGE'
Usage:
  map-kernel-candidates-to-hsaco.sh <kernel_candidates.tsv> [lib_dir]

Or set:
  CANDIDATE_TSV=/path/to/kernel_candidates.tsv
  ROCBLAS_TENSILE_LIBPATH=/path/to/rocblas/library
USAGE
  exit 1
fi

if [[ ! -f "$CANDIDATE_TSV" ]]; then
  echo "ERROR: candidate TSV not found: $CANDIDATE_TSV" >&2
  exit 2
fi
if [[ ! -d "$LIB_DIR" ]]; then
  echo "ERROR: library dir not found: $LIB_DIR" >&2
  exit 3
fi

mkdir -p "$SUMMARY_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
CAND_TAG="$(basename "$CANDIDATE_TSV" .tsv)"
OUT_TSV="$SUMMARY_DIR/hsaco_candidate_map_${CAND_TAG}_${TS}.tsv"
OUT_TXT="$SUMMARY_DIR/hsaco_candidate_map_${CAND_TAG}_${TS}.txt"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HSACO_LIST="$TMP_DIR/hsaco_files.txt"
find "$LIB_DIR" -maxdepth 1 -type f -name '*gfx900*.hsaco' | sort > "$HSACO_LIST"

if [[ ! -s "$HSACO_LIST" ]]; then
  echo "ERROR: no *gfx900*.hsaco files found under: $LIB_DIR" >&2
  exit 4
fi

# Target only tensile_cijk kernels for HSACO mapping.
CAND_LIST="$TMP_DIR/candidates.txt"
awk -F'\t' 'NR>1 && $5=="tensile_cijk" {print $1}' "$CANDIDATE_TSV" > "$CAND_LIST"

if [[ ! -s "$CAND_LIST" ]]; then
  echo "ERROR: no tensile_cijk candidates found in: $CANDIDATE_TSV" >&2
  exit 5
fi

{
  echo -e "kernel_name\tmatch_count\thsaco_files"
  while IFS= read -r kernel; do
    [[ -z "$kernel" ]] && continue
    matches=()
    while IFS= read -r hsaco; do
      # Search binary as text to detect embedded kernel symbols.
      if LC_ALL=C grep -aFq -- "$kernel" "$hsaco"; then
        matches+=("$hsaco")
      fi
    done < "$HSACO_LIST"

    if ((${#matches[@]} > 0)); then
      joined="$(printf '%s;' "${matches[@]}")"
      joined="${joined%;}"
      echo -e "${kernel}\t${#matches[@]}\t${joined}"
    else
      echo -e "${kernel}\t0\t"
    fi
  done < "$CAND_LIST"
} > "$OUT_TSV"

TOTAL_CAND="$(awk 'NR>1 {c++} END {print c+0}' "$OUT_TSV")"
MATCHED_CAND="$(awk -F'\t' 'NR>1 && $2>0 {c++} END {print c+0}' "$OUT_TSV")"
TOTAL_HSACO="$(wc -l < "$HSACO_LIST" | tr -d ' ')"

{
  echo "candidate_tsv=$CANDIDATE_TSV"
  echo "library_dir=$LIB_DIR"
  echo "hsaco_file_count=$TOTAL_HSACO"
  echo "mapped_tsv=$OUT_TSV"
  echo "total_candidates=$TOTAL_CAND"
  echo "matched_candidates=$MATCHED_CAND"
  echo
  echo "--- matched kernels ---"
  awk -F'\t' 'NR>1 && $2>0 {printf "match_count=%s\t%s\n", $2, $1}' "$OUT_TSV" | sort -t$'\t' -k1,1nr
  echo
  echo "--- unmatched kernels ---"
  awk -F'\t' 'NR>1 && $2==0 {print $1}' "$OUT_TSV" || true
} > "$OUT_TXT"

echo "summary=$OUT_TXT"
echo "tsv=$OUT_TSV"
