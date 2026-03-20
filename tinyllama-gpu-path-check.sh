#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MODEL="${MODEL:-tinyllama:latest}"
NUM_PREDICT="${NUM_PREDICT:-420}"
TEMPERATURE="${TEMPERATURE:-0.1}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"

mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
SUMMARY="$LOG_DIR/tinyllama_path_summary_${TS}.txt"
RESTART_SINCE="$(date -Iseconds)"

echo "timestamp=$TS" | tee "$SUMMARY"
echo "model=$MODEL" | tee -a "$SUMMARY"

wait_for_ollama() {
  local i
  for i in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_phase() {
  local phase="$1"
  local since
  local gen_json
  local smi_log
  local j_log

  if [[ "$phase" == "first" ]]; then
    since="$RESTART_SINCE"
  else
    since="$(date -Iseconds)"
  fi
  gen_json="$LOG_DIR/tinyllama_generate_${phase}_${TS}.json"
  smi_log="$LOG_DIR/tinyllama_rocm_smi_${phase}_${TS}.log"
  j_log="$LOG_DIR/tinyllama_journal_${phase}_${TS}.log"

  curl -s http://127.0.0.1:11434/api/generate \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"Generate a 180-word plain-text technical note about validating ROCm on gfx900.\",\"stream\":false,\"keep_alive\":\"0s\",\"options\":{\"num_predict\":${NUM_PREDICT},\"temperature\":${TEMPERATURE}}}" \
    > "$gen_json" &
  local curl_pid=$!

  while kill -0 "$curl_pid" >/dev/null 2>&1; do
    {
      echo "===== $(date -Iseconds) ====="
      rocm-smi --showuse --showmemuse --showpower --showtemp --showclocks 2>/dev/null || rocm-smi 2>/dev/null || true
      echo
    } >> "$smi_log"
    sleep 1
  done

  wait "$curl_pid" || true
  journalctl --user -u ollama --since "$since" --no-pager > "$j_log"

  {
    echo
    echo "== phase=${phase} =="
    echo "generate_json=$gen_json"
    echo "rocm_smi_log=$smi_log"
    echo "journal_log=$j_log"
    echo "-- generate --"
    jq -r '.model,.done,.done_reason,.total_duration,.load_duration,.prompt_eval_count,.eval_count' "$gen_json" 2>/dev/null || cat "$gen_json"
    echo "-- journal key lines --"
    rg -n "inference compute|library=ROCm|library=cpu|discovering available GPUs|failure during GPU discovery|MI25|gfx900|GPULayers:\[\]|device=CPU|offloaded .* layers to GPU|load_tensors:\s+CPU" "$j_log" || true
    echo "-- rocm-smi key lines --"
    rg -n "GPU\[|GPU use|Mem use|Socket Power|Temperature|VRAM" "$smi_log" | head -n 40 || true
  } | tee -a "$SUMMARY"
}

echo "[1/4] restart user ollama service"
systemctl --user restart ollama

echo "[2/4] wait for ollama api"
if ! wait_for_ollama; then
  echo "ERROR: ollama API did not become ready in time" | tee -a "$SUMMARY"
  exit 1
fi

echo "[3/4] run first generate after restart"
run_phase "first"

echo "[4/4] run second generate"
run_phase "second"

echo
echo "summary=$SUMMARY"