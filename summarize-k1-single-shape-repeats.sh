#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SUMMARY_DIR="${SUMMARY_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"

RUN_ROOT="${RUN_ROOT:-${1:-}}"
if [[ -z "$RUN_ROOT" ]]; then
  echo "Usage: RUN_ROOT=<run-root> $0" >&2
  echo "Example: RUN_ROOT=k1_entry_20260325_1shape $0" >&2
  exit 1
fi

if [[ ! -d "$SUMMARY_DIR" ]]; then
  echo "ERROR: summary dir not found: $SUMMARY_DIR" >&2
  exit 1
fi

mapfile -t TSV_FILES < <(
  find "$SUMMARY_DIR" -maxdepth 1 -type f \
    -name "g4_k1_single_shape_loop_${RUN_ROOT}*.tsv" \
    ! -name "*_index.tsv" \
    -print | sort
)

if [[ "${#TSV_FILES[@]}" -eq 0 ]]; then
  echo "ERROR: no loop tsv matched run root: $RUN_ROOT" >&2
  exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
OUT_TSV="$SUMMARY_DIR/g4_k1_single_shape_repeat_summary_${RUN_ROOT}_${TS}.tsv"
OUT_TXT="$SUMMARY_DIR/g4_k1_single_shape_repeat_summary_${RUN_ROOT}_${TS}.txt"
OUT_DETAIL="$SUMMARY_DIR/g4_k1_single_shape_repeat_detail_${RUN_ROOT}_${TS}.tsv"

{
  echo -e "run_tag\tlane\trocblas_tensile_libpath\ttarget_shape_mnk\tfallback_confirmed\tdispatch_confirmed\tdirect_rocblas_or_tensile_dispatch\tfallback_dat_openat\tfallback_hsaco_openat\trocblas_trace_gemm_lines\tkernel_dispatch_rows\tkernel_tensile_like_rows\tphase_split_status_proxy\tshape_target_hits\tttft_ms\ttotal_ms\ttok_s\tcanonical_link_summary\tcanonical_strace_summary\tcanonical_rocprof_summary\tcanonical_shape_tsv\tcanonical_shape_summary"
} > "$OUT_DETAIL"

for f in "${TSV_FILES[@]}"; do
  base="$(basename "$f")"
  run_tag="${base#g4_k1_single_shape_loop_}"
  run_tag="${run_tag%.tsv}"
  awk -F'\t' -v OFS='\t' -v tag="$run_tag" 'NR > 1 { print tag, $0 }' "$f" >> "$OUT_DETAIL"
done

python3 - "$OUT_DETAIL" "$OUT_TSV" "$OUT_TXT" "$RUN_ROOT" "${TSV_FILES[@]}" <<'PY'
import csv
import statistics
import sys
from collections import defaultdict

detail_path, out_tsv, out_txt, run_root = sys.argv[1:5]
input_files = sys.argv[5:]

rows_by_lane = defaultdict(list)
with open(detail_path, "r", encoding="utf-8", newline="") as f:
    reader = csv.DictReader(f, delimiter="\t")
    for row in reader:
        rows_by_lane[row["lane"]].append(row)

def as_float(v: str) -> float:
    try:
        return float(v)
    except Exception:
        return 0.0

def as_int(v: str) -> int:
    try:
        return int(float(v))
    except Exception:
        return 0

def avg(vals):
    return statistics.fmean(vals) if vals else 0.0

def lane_summary(lane_rows):
    runs = sorted({r["run_tag"] for r in lane_rows})
    shape_set = sorted({r["target_shape_mnk"] for r in lane_rows if r["target_shape_mnk"]})
    path_set = sorted({r["rocblas_tensile_libpath"] for r in lane_rows if r["rocblas_tensile_libpath"]})
    phase_set = sorted({r["phase_split_status_proxy"] for r in lane_rows if r["phase_split_status_proxy"]})

    fallback_vals = [as_int(r["fallback_confirmed"]) for r in lane_rows]
    dispatch_vals = [as_int(r["dispatch_confirmed"]) for r in lane_rows]
    direct_vals = [as_int(r["direct_rocblas_or_tensile_dispatch"]) for r in lane_rows]
    shape_hits_vals = [as_int(r["shape_target_hits"]) for r in lane_rows]
    kernel_dispatch_vals = [as_int(r["kernel_dispatch_rows"]) for r in lane_rows]
    gemm_vals = [as_int(r["rocblas_trace_gemm_lines"]) for r in lane_rows]
    ttft_vals = [as_float(r["ttft_ms"]) for r in lane_rows]
    total_vals = [as_float(r["total_ms"]) for r in lane_rows]
    tok_vals = [as_float(r["tok_s"]) for r in lane_rows]

    return {
        "run_count": len(runs),
        "runs_csv": ",".join(runs),
        "shape_set": ",".join(shape_set),
        "path_set": ",".join(path_set),
        "phase_set": ",".join(phase_set),
        "fallback_all_same": 1 if len(set(fallback_vals)) == 1 else 0,
        "dispatch_all_same": 1 if len(set(dispatch_vals)) == 1 else 0,
        "direct_all_same": 1 if len(set(direct_vals)) == 1 else 0,
        "shape_hits_all_same": 1 if len(set(shape_hits_vals)) == 1 else 0,
        "fallback_mode": max(set(fallback_vals), key=fallback_vals.count) if fallback_vals else 0,
        "dispatch_mode": max(set(dispatch_vals), key=dispatch_vals.count) if dispatch_vals else 0,
        "direct_mode": max(set(direct_vals), key=direct_vals.count) if direct_vals else 0,
        "shape_hits_mode": max(set(shape_hits_vals), key=shape_hits_vals.count) if shape_hits_vals else 0,
        "kernel_dispatch_avg": avg(kernel_dispatch_vals),
        "kernel_dispatch_min": min(kernel_dispatch_vals) if kernel_dispatch_vals else 0,
        "kernel_dispatch_max": max(kernel_dispatch_vals) if kernel_dispatch_vals else 0,
        "gemm_avg": avg(gemm_vals),
        "gemm_min": min(gemm_vals) if gemm_vals else 0,
        "gemm_max": max(gemm_vals) if gemm_vals else 0,
        "ttft_avg": avg(ttft_vals),
        "ttft_min": min(ttft_vals) if ttft_vals else 0.0,
        "ttft_max": max(ttft_vals) if ttft_vals else 0.0,
        "total_avg": avg(total_vals),
        "total_min": min(total_vals) if total_vals else 0.0,
        "total_max": max(total_vals) if total_vals else 0.0,
        "tok_avg": avg(tok_vals),
        "tok_min": min(tok_vals) if tok_vals else 0.0,
        "tok_max": max(tok_vals) if tok_vals else 0.0,
    }

lane_stats = {lane: lane_summary(rows) for lane, rows in sorted(rows_by_lane.items())}

with open(out_tsv, "w", encoding="utf-8", newline="") as f:
    writer = csv.writer(f, delimiter="\t")
    writer.writerow([
        "lane", "run_count", "runs_csv", "target_shape_set", "libpath_set", "phase_set",
        "fallback_mode", "fallback_all_same",
        "dispatch_mode", "dispatch_all_same",
        "direct_mode", "direct_all_same",
        "shape_hits_mode", "shape_hits_all_same",
        "kernel_dispatch_avg", "kernel_dispatch_min", "kernel_dispatch_max",
        "rocblas_trace_gemm_avg", "rocblas_trace_gemm_min", "rocblas_trace_gemm_max",
        "ttft_ms_avg", "ttft_ms_min", "ttft_ms_max",
        "total_ms_avg", "total_ms_min", "total_ms_max",
        "tok_s_avg", "tok_s_min", "tok_s_max",
    ])
    for lane, s in lane_stats.items():
        writer.writerow([
            lane, s["run_count"], s["runs_csv"], s["shape_set"], s["path_set"], s["phase_set"],
            s["fallback_mode"], s["fallback_all_same"],
            s["dispatch_mode"], s["dispatch_all_same"],
            s["direct_mode"], s["direct_all_same"],
            s["shape_hits_mode"], s["shape_hits_all_same"],
            f"{s['kernel_dispatch_avg']:.3f}", s["kernel_dispatch_min"], s["kernel_dispatch_max"],
            f"{s['gemm_avg']:.3f}", s["gemm_min"], s["gemm_max"],
            f"{s['ttft_avg']:.3f}", f"{s['ttft_min']:.3f}", f"{s['ttft_max']:.3f}",
            f"{s['total_avg']:.3f}", f"{s['total_min']:.3f}", f"{s['total_max']:.3f}",
            f"{s['tok_avg']:.4f}", f"{s['tok_min']:.4f}", f"{s['tok_max']:.4f}",
        ])

ratio_ttft = "n/a"
ratio_total = "n/a"
ratio_tok = "n/a"
if "aets" in lane_stats and "system" in lane_stats:
    a = lane_stats["aets"]
    s = lane_stats["system"]
    if s["ttft_avg"] > 0:
        ratio_ttft = f"{a['ttft_avg']/s['ttft_avg']:.4f}"
    if s["total_avg"] > 0:
        ratio_total = f"{a['total_avg']/s['total_avg']:.4f}"
    if s["tok_avg"] > 0:
        ratio_tok = f"{a['tok_avg']/s['tok_avg']:.4f}"

with open(out_txt, "w", encoding="utf-8") as f:
    f.write(f"run_root={run_root}\n")
    f.write(f"input_count={len(input_files)}\n")
    for i, p in enumerate(input_files, start=1):
        f.write(f"input_{i}={p}\n")
    f.write(f"detail_tsv={detail_path}\n")
    f.write(f"summary_tsv={out_tsv}\n")
    f.write("\n--- lane summary ---\n")
    for lane, s in lane_stats.items():
        f.write(f"[{lane}] runs={s['run_count']} phase_set={s['phase_set'] or 'none'}\n")
        f.write(f"  fallback_mode={s['fallback_mode']} all_same={s['fallback_all_same']}\n")
        f.write(f"  dispatch_mode={s['dispatch_mode']} all_same={s['dispatch_all_same']}\n")
        f.write(f"  direct_mode={s['direct_mode']} all_same={s['direct_all_same']}\n")
        f.write(f"  shape_hits_mode={s['shape_hits_mode']} all_same={s['shape_hits_all_same']}\n")
        f.write(f"  ttft_ms(avg/min/max)={s['ttft_avg']:.3f}/{s['ttft_min']:.3f}/{s['ttft_max']:.3f}\n")
        f.write(f"  total_ms(avg/min/max)={s['total_avg']:.3f}/{s['total_min']:.3f}/{s['total_max']:.3f}\n")
        f.write(f"  tok_s(avg/min/max)={s['tok_avg']:.4f}/{s['tok_min']:.4f}/{s['tok_max']:.4f}\n")
    f.write("\n--- aets_vs_system_avg_ratio ---\n")
    f.write(f"ttft_ratio_aets_over_system={ratio_ttft}\n")
    f.write(f"total_ratio_aets_over_system={ratio_total}\n")
    f.write(f"tok_s_ratio_aets_over_system={ratio_tok}\n")
PY

echo "summary=$OUT_TXT"
echo "tsv=$OUT_TSV"
echo "detail=$OUT_DETAIL"
