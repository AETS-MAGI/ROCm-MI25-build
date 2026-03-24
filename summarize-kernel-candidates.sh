#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SUMMARY_DIR="${SUMMARY_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"

PREFILL_ROCPROF_SUMMARY="${PREFILL_ROCPROF_SUMMARY:-${1:-}}"
FULL_ROCPROF_SUMMARY="${FULL_ROCPROF_SUMMARY:-${2:-}}"

if [[ -z "$PREFILL_ROCPROF_SUMMARY" || -z "$FULL_ROCPROF_SUMMARY" ]]; then
  cat >&2 <<'USAGE'
Usage:
  summarize-kernel-candidates.sh <prefill_rocprof_summary.txt> <full_rocprof_summary.txt>

Or set:
  PREFILL_ROCPROF_SUMMARY=/path/to/prefill_summary.txt
  FULL_ROCPROF_SUMMARY=/path/to/full_summary.txt
USAGE
  exit 1
fi

if [[ ! -f "$PREFILL_ROCPROF_SUMMARY" ]]; then
  echo "ERROR: prefill rocprof summary not found: $PREFILL_ROCPROF_SUMMARY" >&2
  exit 2
fi
if [[ ! -f "$FULL_ROCPROF_SUMMARY" ]]; then
  echo "ERROR: full rocprof summary not found: $FULL_ROCPROF_SUMMARY" >&2
  exit 3
fi

mkdir -p "$SUMMARY_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
PREFILL_TAG="$(basename "$PREFILL_ROCPROF_SUMMARY" .txt)"
FULL_TAG="$(basename "$FULL_ROCPROF_SUMMARY" .txt)"
OUT_TSV="$SUMMARY_DIR/kernel_candidates_${PREFILL_TAG}__${FULL_TAG}_${TS}.tsv"
OUT_TXT="$SUMMARY_DIR/kernel_candidates_${PREFILL_TAG}__${FULL_TAG}_${TS}.txt"

python3 - "$PREFILL_ROCPROF_SUMMARY" "$FULL_ROCPROF_SUMMARY" "$OUT_TSV" "$OUT_TXT" <<'PY'
import csv
import os
import re
import sys
from collections import Counter

prefill_summary, full_summary, out_tsv, out_txt = sys.argv[1:5]


def read_kv(path):
    kv = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                kv[k.strip()] = v.strip()
    return kv


def extract_kernel_trace_path(summary_path):
    kv = read_kv(summary_path)
    p = kv.get("kernel_trace_file", "")
    if p and os.path.isfile(p):
        return p
    raise SystemExit(f"ERROR: kernel_trace_file not found from summary: {summary_path}")


def collect_kernel_counts(kernel_trace_csv):
    counts = Counter()
    with open(kernel_trace_csv, "r", encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("Kind", "") != "KERNEL_DISPATCH":
                continue
            name = row.get("Kernel_Name", "").strip()
            if not name:
                continue
            counts[name] += 1
    return counts


def classify_kernel(name):
    if name.startswith("Cijk_"):
        return "tensile_cijk"
    if "mul_mat_q<" in name:
        return "ggml_mul_mat_q"
    if "mul_mat_vec_q<" in name:
        return "ggml_mul_mat_vec_q"
    if "mul_mat_vec_f<" in name:
        return "ggml_mul_mat_vec_f"
    if "quantize_" in name:
        return "ggml_quantize"
    if "__amd_rocclr_copyBuffer" in name or "__amd_rocclr_fillBufferAligned" in name:
        return "runtime_copy_fill"
    if "k_bin_bcast<" in name:
        return "ggml_elementwise"
    if "soft_max_f32<" in name:
        return "ggml_softmax"
    if "rope_" in name:
        return "ggml_rope"
    if "rms_norm_f32<" in name:
        return "ggml_norm"
    return "other"


prefill_trace = extract_kernel_trace_path(prefill_summary)
full_trace = extract_kernel_trace_path(full_summary)

prefill_counts = collect_kernel_counts(prefill_trace)
full_counts = collect_kernel_counts(full_trace)

all_names = set(prefill_counts.keys()) | set(full_counts.keys())

rows = []
for name in all_names:
    p = prefill_counts.get(name, 0)
    f = full_counts.get(name, 0)
    d = f - p
    cat = classify_kernel(name)
    # Candidate score:
    # - prioritize kernel families likely tied to matmul path
    # - then prioritize higher full volume and positive delta
    score = 0
    if cat in {"tensile_cijk", "ggml_mul_mat_q", "ggml_mul_mat_vec_q", "ggml_mul_mat_vec_f"}:
        score += 1_000_000
    score += f * 100
    score += max(d, 0)
    rows.append((score, name, p, f, d, cat))

rows.sort(key=lambda x: (-x[0], -x[4], -x[3], x[5], x[1]))

with open(out_tsv, "w", encoding="utf-8", newline="") as f:
    w = csv.writer(f, delimiter="\t")
    w.writerow(["kernel_name", "prefill_count", "full_count", "delta", "category", "candidate_score"])
    for score, name, p, full, d, cat in rows:
        w.writerow([name, p, full, d, cat, score])

total_prefill = sum(prefill_counts.values())
total_full = sum(full_counts.values())
total_delta = total_full - total_prefill

def topn(predicate, n=15):
    out = []
    for score, name, p, full, d, cat in rows:
        if predicate(score, name, p, full, d, cat):
            out.append((name, p, full, d, cat, score))
        if len(out) >= n:
            break
    return out


matmul_top = topn(lambda s, n, p, f, d, c: c in {
    "tensile_cijk", "ggml_mul_mat_q", "ggml_mul_mat_vec_q", "ggml_mul_mat_vec_f"
})
delta_top = topn(lambda s, n, p, f, d, c: d > 0)
full_top = topn(lambda s, n, p, f, d, c: True)

with open(out_txt, "w", encoding="utf-8") as f:
    f.write(f"prefill_summary={prefill_summary}\n")
    f.write(f"full_summary={full_summary}\n")
    f.write(f"prefill_kernel_trace={prefill_trace}\n")
    f.write(f"full_kernel_trace={full_trace}\n")
    f.write(f"out_tsv={out_tsv}\n")
    f.write(f"total_prefill_dispatch_rows={total_prefill}\n")
    f.write(f"total_full_dispatch_rows={total_full}\n")
    f.write(f"total_delta_dispatch_rows={total_delta}\n")
    f.write("\n")
    f.write("--- top_matmul_candidates ---\n")
    if matmul_top:
        for name, p, full, d, cat, score in matmul_top:
            f.write(f"{cat}\tprefill={p}\tfull={full}\tdelta={d}\tscore={score}\t{name}\n")
    else:
        f.write("none\n")
    f.write("\n")
    f.write("--- top_positive_delta ---\n")
    if delta_top:
        for name, p, full, d, cat, score in delta_top:
            f.write(f"{cat}\tprefill={p}\tfull={full}\tdelta={d}\tscore={score}\t{name}\n")
    else:
        f.write("none\n")
    f.write("\n")
    f.write("--- top_full_dispatch ---\n")
    if full_top:
        for name, p, full, d, cat, score in full_top:
            f.write(f"{cat}\tprefill={p}\tfull={full}\tdelta={d}\tscore={score}\t{name}\n")
    else:
        f.write("none\n")

print(f"summary={out_txt}")
print(f"tsv={out_tsv}")
PY
