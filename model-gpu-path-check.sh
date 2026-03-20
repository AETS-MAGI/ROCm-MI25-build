#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MODEL="${MODEL:-${1:-tinyllama:latest}}"
PROMPT="${PROMPT:-Generate a 180-word plain-text technical note about validating ROCm on gfx900.}"
NUM_PREDICT="${NUM_PREDICT:-220}"
TEMPERATURE="${TEMPERATURE:-0.1}"
KEEP_ALIVE="${KEEP_ALIVE:-0s}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"

mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
START_ISO="$(date -Iseconds)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"

GEN_LOG="$LOG_DIR/model_generate_${MODEL_TAG}_${TS}.json"
SMI_LOG="$LOG_DIR/model_rocm_smi_${MODEL_TAG}_${TS}.log"
J_LOG="$LOG_DIR/model_journal_${MODEL_TAG}_${TS}.log"
SUMMARY="$LOG_DIR/model_summary_${MODEL_TAG}_${TS}.txt"

echo "model=$MODEL" | tee "$SUMMARY"
echo "timestamp=$TS" | tee -a "$SUMMARY"

curl -s http://127.0.0.1:11434/api/generate \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"${PROMPT}\",\"stream\":false,\"keep_alive\":\"${KEEP_ALIVE}\",\"options\":{\"num_predict\":${NUM_PREDICT},\"temperature\":${TEMPERATURE}}}" \
  > "$GEN_LOG" &
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

{
  echo "GEN_LOG=$GEN_LOG"
  echo "SMI_LOG=$SMI_LOG"
  echo "J_LOG=$J_LOG"
  echo "--- generate result ---"
  jq -r '.model,.done,.done_reason,.total_duration,.load_duration,.prompt_eval_count,.eval_count' "$GEN_LOG" 2>/dev/null || cat "$GEN_LOG"
  echo
  echo "--- journal key lines ---"
  rg -n "inference compute|library=ROCm|library=cpu|compute=gfx900|Radeon Instinct MI25|GPULayers|offloaded .* layers to GPU|failure during GPU discovery|out of memory|abort|killed" "$J_LOG" || true
  echo
  echo "--- rocm-smi key lines ---"
  rg -n "GPU use|Current Socket Graphics Package Power|GPU Memory Allocated|Temperature" "$SMI_LOG" | head -n 140 || true
} | tee -a "$SUMMARY"
