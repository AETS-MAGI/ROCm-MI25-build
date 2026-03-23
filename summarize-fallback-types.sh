#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${1:-vega_path_check_logs}"
GLOB="${2:-g4_strace_openat_tinyllama_latest_20260324_005717.log.*}"
OUT="${3:-$LOG_DIR/fallback_type_summary_$(date +%Y%m%d_%H%M%S).txt}"

if [[ ! -d "$LOG_DIR" ]]; then
  echo "[error] log dir not found: $LOG_DIR" >&2
  exit 1
fi

mapfile -t FILES < <(cd "$LOG_DIR" && ls -1 $GLOB 2>/dev/null || true)
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "[error] no files matched: $LOG_DIR/$GLOB" >&2
  exit 1
fi

python3 - "$LOG_DIR" "$OUT" "${FILES[@]}" <<'PY'
import re
import sys
from collections import Counter
from pathlib import Path

log_dir = Path(sys.argv[1])
out_path = Path(sys.argv[2])
files = [log_dir / p for p in sys.argv[3:]]

pat_dat = re.compile(r"TensileLibrary_(Type_[^/]+?)_Contraction[^/]*_fallback\.dat")
pat_hsaco = re.compile(r"TensileLibrary_(Type_[^/]+?)_fallback(?:_[^/]+)?\.hsaco")

by_type = Counter()
by_type_ext = Counter()
by_file = Counter()
line_total = 0
match_total = 0

for fp in files:
    try:
        text = fp.read_text(encoding="utf-8", errors="replace")
    except Exception:
        continue
    for line in text.splitlines():
        line_total += 1
        m = pat_dat.search(line)
        if m:
            t, ext = m.group(1), "dat"
        else:
            m = pat_hsaco.search(line)
            if not m:
                continue
            t, ext = m.group(1), "hsaco"
        if "_Contraction" in t:
            t = t.split("_Contraction", 1)[0]
        by_type[t] += 1
        by_type_ext[(t, ext)] += 1
        by_file[fp.name] += 1
        match_total += 1

out = []
out.append("# Fallback Type Summary")
out.append("")
out.append(f"log_dir: {log_dir}")
out.append(f"files: {len(files)}")
out.append(f"matched_lines: {match_total}")
out.append(f"scanned_lines: {line_total}")
out.append("")
out.append("## by file")
for name, c in sorted(by_file.items(), key=lambda x: (-x[1], x[0])):
    out.append(f"- {name}: {c}")
out.append("")
out.append("## by type")
for t, c in sorted(by_type.items(), key=lambda x: (-x[1], x[0])):
    out.append(f"- {t}: {c}")
out.append("")
out.append("## by type + ext")
for (t, ext), c in sorted(by_type_ext.items(), key=lambda x: (-x[1], x[0][0], x[0][1])):
    out.append(f"- {t}.{ext}: {c}")

out_path.write_text("\n".join(out) + "\n", encoding="utf-8")
print(out_path)
PY

echo "[done] wrote summary: $OUT"
