#!/usr/bin/env bash

set -e
cd /home/${USER}/ROCm-project
TS="$(date +%Y%m%d_%H%M%S)"
START_ISO="$(date -Iseconds)"
GEN_LOG="vega_path_check_logs/deepseek14b_generate_${TS}.json"
SMI_LOG="vega_path_check_logs/deepseek14b_rocm_smi_${TS}.log"
J_LOG="vega_path_check_logs/deepseek14b_journal_${TS}.log"

curl -s http://127.0.0.1:11434/api/generate \
  -d '{"model":"deepseek-r1:14b","prompt":"hi","stream":false}' > "$GEN_LOG" &
CURL_PID=$!

while kill -0 "$CURL_PID" >/dev/null 2>&1; do
  {
    echo "===== $(date -Iseconds) ====="
    rocm-smi --showuse --showmemuse --showpower --showtemp --showclocks 2>/dev/null || rocm-smi 2>/dev/null || true
    echo
  } >> "$SMI_LOG"
  sleep 1
done

wait "$CURL_PID" || true

journalctl --user -u ollama --since "$START_ISO" --no-pager > "$J_LOG"

echo "GEN_LOG=$GEN_LOG"
echo "SMI_LOG=$SMI_LOG"
echo "J_LOG=$J_LOG"
echo "--- generate result ---"
cat "$GEN_LOG"
echo
echo "--- journal key lines ---"
rg -n "discovering available GPUs|inference compute|failure during GPU discovery|runner crashed|rocBLAS|gfx900|library=ROCm|library=cpu|out of memory|abort|killed" "$J_LOG" || true