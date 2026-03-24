#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SUMMARY_DIR="${SUMMARY_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"
LLVM_OBJDUMP="${LLVM_OBJDUMP:-/opt/rocm/llvm/bin/llvm-objdump}"

HSACO_DIR="${HSACO_DIR:-${1:-}}"

if [[ -z "$HSACO_DIR" ]]; then
  cat >&2 <<'USAGE'
Usage:
  summarize-hsaco-disasm-signals.sh <hsaco_target_dir>

Or set:
  HSACO_DIR=/path/to/hsaco_targets_*
USAGE
  exit 1
fi

if [[ ! -d "$HSACO_DIR" ]]; then
  echo "ERROR: hsaco target dir not found: $HSACO_DIR" >&2
  exit 2
fi
if [[ ! -x "$LLVM_OBJDUMP" ]]; then
  echo "ERROR: llvm-objdump not executable: $LLVM_OBJDUMP" >&2
  exit 3
fi

mkdir -p "$SUMMARY_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
DIR_TAG="$(basename "$HSACO_DIR")"
OUT_DIR="$SUMMARY_DIR/disasm_${DIR_TAG}_${TS}"
OUT_TSV="$SUMMARY_DIR/disasm_signal_summary_${DIR_TAG}_${TS}.tsv"
OUT_TXT="$SUMMARY_DIR/disasm_signal_summary_${DIR_TAG}_${TS}.txt"

mkdir -p "$OUT_DIR"

shopt -s nullglob
hsacos=("$HSACO_DIR"/*.hsaco)
if ((${#hsacos[@]} == 0)); then
  echo "ERROR: no .hsaco files in $HSACO_DIR" >&2
  exit 4
fi

printf '%s\n' "hsaco_file	disasm_path	total_lines	dot4_lines	packed_lines	mfma_lines	fma_mac_mad_lines	memory_lines" > "$OUT_TSV"

total_files=0
dot4_positive=0
packed_positive=0
mfma_positive=0
memory_positive=0

for hsaco in "${hsacos[@]}"; do
  base="$(basename "$hsaco")"
  disasm="$OUT_DIR/${base}.disasm.s"
  "$LLVM_OBJDUMP" -d --no-show-raw-insn "$hsaco" > "$disasm"

  total_lines="$(wc -l < "$disasm" | tr -d ' ')"
  dot4_lines="$({ rg -n -i 'v_dot4|v_dot2' "$disasm" || true; } | wc -l | tr -d ' ')"
  packed_lines="$({ rg -n -i '\bv_pk_' "$disasm" || true; } | wc -l | tr -d ' ')"
  mfma_lines="$({ rg -n -i '\bv_mfma' "$disasm" || true; } | wc -l | tr -d ' ')"
  fma_lines="$({ rg -n -i '\bv_fma|\bv_mac|\bv_mad' "$disasm" || true; } | wc -l | tr -d ' ')"
  memory_lines="$({ rg -n -i 'buffer_|global_|flat_|ds_read|ds_write|scratch_' "$disasm" || true; } | wc -l | tr -d ' ')"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$hsaco" "$disasm" "$total_lines" "$dot4_lines" "$packed_lines" "$mfma_lines" "$fma_lines" "$memory_lines" \
    >> "$OUT_TSV"

  total_files=$((total_files + 1))
  (( dot4_lines > 0 )) && dot4_positive=$((dot4_positive + 1))
  (( packed_lines > 0 )) && packed_positive=$((packed_positive + 1))
  (( mfma_lines > 0 )) && mfma_positive=$((mfma_positive + 1))
  (( memory_lines > 0 )) && memory_positive=$((memory_positive + 1))
done

{
  echo "hsaco_dir=$HSACO_DIR"
  echo "llvm_objdump=$LLVM_OBJDUMP"
  echo "disasm_dir=$OUT_DIR"
  echo "summary_tsv=$OUT_TSV"
  echo "total_files=$total_files"
  echo "dot4_positive_files=$dot4_positive"
  echo "packed_positive_files=$packed_positive"
  echo "mfma_positive_files=$mfma_positive"
  echo "memory_positive_files=$memory_positive"
  echo
  echo "--- per-file summary ---"
  cat "$OUT_TSV"
} > "$OUT_TXT"

echo "summary=$OUT_TXT"
echo "tsv=$OUT_TSV"
echo "disasm_dir=$OUT_DIR"
