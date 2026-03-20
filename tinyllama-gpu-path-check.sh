#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MODEL="${MODEL:-tinyllama:latest}"
NUM_PREDICT="${NUM_PREDICT:-420}"
TEMPERATURE="${TEMPERATURE:-0.1}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"
AB_ENABLE="${AB_ENABLE:-1}"
BACKEND_DIR="${BACKEND_DIR:-/home/limonene/ROCm-project/ollama-src/build/lib/ollama}"
CASE_FILTER="${CASE_FILTER:-}"

mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
SUMMARY="$LOG_DIR/tinyllama_path_summary_${TS}.txt"
INDEX_TSV="$LOG_DIR/tinyllama_path_index_${TS}.tsv"
PROMPT_MAIN="Generate a 180-word plain-text technical note about validating ROCm on gfx900."
PROMPT_WARMUP="warmup"

echo "timestamp=$TS" | tee "$SUMMARY"
echo "model=$MODEL" | tee -a "$SUMMARY"
echo -e "case\tphase\tverdict\tmax_gpu_use\tinference_library\tinference_compute\tgpulayers\tjson\tjournal\trocm_smi" > "$INDEX_TSV"

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

check_backend_files() {
  local missing=0
  local required=(
    "libggml-hip.so"
    "libggml-base.so"
    "libggml-cpu-haswell.so"
  )

  if [[ ! -d "$BACKEND_DIR" ]]; then
    echo "ERROR: backend directory is missing: $BACKEND_DIR" | tee -a "$SUMMARY"
    return 1
  fi

  for f in "${required[@]}"; do
    if [[ ! -f "$BACKEND_DIR/$f" ]]; then
      echo "ERROR: backend file is missing: $BACKEND_DIR/$f" | tee -a "$SUMMARY"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    return 1
  fi

  {
    echo "backend_dir=$BACKEND_DIR"
    echo "backend_check=ok"
  } | tee -a "$SUMMARY"
}

run_generate() {
  local case_name="$1"
  local phase="$2"
  local keep_alive="$3"
  local since="$4"
  local prompt="$5"
  local gen_json
  local smi_log
  local j_log
  local max_gpu_use
  local verdict
  local inference_library
  local inference_compute
  local gpulayers

  gen_json="$LOG_DIR/tinyllama_generate_${case_name}_${phase}_${TS}.json"
  smi_log="$LOG_DIR/tinyllama_rocm_smi_${case_name}_${phase}_${TS}.log"
  j_log="$LOG_DIR/tinyllama_journal_${case_name}_${phase}_${TS}.log"

  curl -s http://127.0.0.1:11434/api/generate \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"${prompt}\",\"stream\":false,\"keep_alive\":\"${keep_alive}\",\"options\":{\"num_predict\":${NUM_PREDICT},\"temperature\":${TEMPERATURE}}}" \
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

  max_gpu_use="$(rg -o "GPU use \(%\): [0-9]+" "$smi_log" | awk '{print $4}' | sort -nr | head -n 1)"
  max_gpu_use="${max_gpu_use:-0}"
  verdict="$(judge_path "$j_log" "$smi_log")"
  inference_library="$(extract_inference_library "$j_log")"
  inference_compute="$(extract_inference_compute "$j_log")"
  gpulayers="$(extract_gpulayers "$j_log")"

  echo -e "${case_name}\t${phase}\t${verdict}\t${max_gpu_use}\t${inference_library}\t${inference_compute}\t${gpulayers}\t${gen_json}\t${j_log}\t${smi_log}" >> "$INDEX_TSV"

  {
    echo
    echo "== case=${case_name} phase=${phase} keep_alive=${keep_alive} =="
    echo "verdict=${verdict}"
    echo "max_gpu_use=${max_gpu_use}"
    echo "inference_library=${inference_library}"
    echo "inference_compute=${inference_compute}"
    echo "gpulayers=${gpulayers}"
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

extract_inference_library() {
  local j_log="$1"
  local line
  line="$(rg -o "library=[^ ]+" "$j_log" | head -n 1 || true)"
  if [[ -n "$line" ]]; then
    echo "${line#library=}"
  else
    echo "unknown"
  fi
}

extract_inference_compute() {
  local j_log="$1"
  local line
  line="$(rg -o "compute=[^ ]*" "$j_log" | head -n 1 || true)"
  if [[ -n "$line" ]]; then
    echo "${line#compute=}"
  else
    echo "unknown"
  fi
}

extract_gpulayers() {
  local j_log="$1"
  local line
  line="$(rg -o "GPULayers:[^}]*(]|\})" "$j_log" | head -n 1 || true)"
  if [[ -n "$line" ]]; then
    echo "$line"
  else
    echo "unknown"
  fi
}

judge_path() {
  local j_log="$1"
  local smi_log="$2"
  local has_gpu="0"
  local has_cpu="0"
  local max_gpu_use="0"

  if rg -q "library=ROCm|compute=gfx900|offloaded .* layers to GPU|using device ROCm" "$j_log"; then
    has_gpu="1"
  fi
  if rg -q "inference compute.*library=cpu|GPULayers:\[\]|device=CPU size=|load_tensors:\s+CPU model buffer size" "$j_log"; then
    has_cpu="1"
  fi

  max_gpu_use="$(rg -o "GPU use \(%\): [0-9]+" "$smi_log" | awk '{print $4}' | sort -nr | head -n 1)"
  max_gpu_use="${max_gpu_use:-0}"
  if [[ "$max_gpu_use" -gt 0 ]]; then
    has_gpu="1"
  fi

  if [[ "$has_gpu" == "1" && "$has_cpu" == "0" ]]; then
    echo "GPU"
  elif [[ "$has_cpu" == "1" && "$has_gpu" == "0" ]]; then
    echo "CPU"
  elif [[ "$has_cpu" == "1" && "$has_gpu" == "1" ]]; then
    echo "MIXED"
  else
    echo "UNSURE"
  fi
}

run_case() {
  local case_name="$1"
  local do_restart="$2"
  local do_warmup="$3"
  local keep_alive="$4"
  local case_since
  local phase_since

  echo
  echo "[case ${case_name}] restart=${do_restart} warmup=${do_warmup} keep_alive=${keep_alive}" | tee -a "$SUMMARY"

  case_since="$(date -Iseconds)"
  if [[ "$do_restart" == "1" ]]; then
    echo "[case ${case_name}] restarting user ollama service" | tee -a "$SUMMARY"
    systemctl --user restart ollama
    if ! wait_for_ollama; then
      echo "ERROR: ollama API did not become ready in time for case=${case_name}" | tee -a "$SUMMARY"
      return 1
    fi
    case_since="$(date -Iseconds)"
  fi

  if [[ "$do_warmup" == "1" ]]; then
    echo "[case ${case_name}] warm-up request" | tee -a "$SUMMARY"
    curl -s http://127.0.0.1:11434/api/generate \
      -d "{\"model\":\"${MODEL}\",\"prompt\":\"${PROMPT_WARMUP}\",\"stream\":false,\"keep_alive\":\"${keep_alive}\",\"options\":{\"num_predict\":16,\"temperature\":0.0}}" \
      > "$LOG_DIR/tinyllama_warmup_${case_name}_${TS}.json" || true
  fi

  phase_since="$case_since"
  run_generate "$case_name" "first" "$keep_alive" "$phase_since" "$PROMPT_MAIN"
  phase_since="$(date -Iseconds)"
  run_generate "$case_name" "second" "$keep_alive" "$phase_since" "$PROMPT_MAIN"
}

should_run_case() {
  local case_name="$1"
  if [[ -z "$CASE_FILTER" ]]; then
    return 0
  fi
  if printf '%s' "$CASE_FILTER" | tr ',' '\n' | rg -x "$case_name" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

print_index_summary() {
  {
    echo
    echo "== index summary (verdict count) =="
    awk -F'\t' 'NR>1 { key=$3; c[key]++ } END { for (k in c) printf("%s\t%d\n", k, c[k]) }' "$INDEX_TSV" | sort
    echo
    echo "== per-case compact view =="
    awk -F'\t' 'NR==1 {next} {k=$1; phase=$2; verdict[k,phase]=$3; gpu[k,phase]=$4; lib[k,phase]=$5; comp[k,phase]=$6; gl[k,phase]=$7; seen[k]=1}
      END {
        printf("case\tfirst\tsecond\tfirst_gpu\tsecond_gpu\tfirst_lib\tsecond_lib\tfirst_comp\tsecond_comp\tfirst_gpulayers\tsecond_gpulayers\n");
        for (k in seen) {
          printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", k, verdict[k,"first"], verdict[k,"second"], gpu[k,"first"], gpu[k,"second"], lib[k,"first"], lib[k,"second"], comp[k,"first"], comp[k,"second"], gl[k,"first"], gl[k,"second"]);
        }
      }' "$INDEX_TSV" | sort
    echo
    echo "index_tsv=$INDEX_TSV"
  } | tee -a "$SUMMARY"
}

echo "[0/2] ensure ollama api is reachable"
if ! wait_for_ollama; then
  echo "ERROR: ollama API is not reachable" | tee -a "$SUMMARY"
  exit 1
fi

echo "[0.5/2] check backend files"
if ! check_backend_files; then
  echo "ERROR: backend preflight failed" | tee -a "$SUMMARY"
  exit 1
fi

if [[ "$AB_ENABLE" == "1" ]]; then
  # A/B matrix focused on restart, warm-up, keep_alive.
  if should_run_case "r1_w0_k0"; then run_case "r1_w0_k0" "1" "0" "0s"; fi
  if should_run_case "r1_w1_k0"; then run_case "r1_w1_k0" "1" "1" "0s"; fi
  if should_run_case "r1_w0_k1"; then run_case "r1_w0_k1" "1" "0" "10m"; fi
  if should_run_case "r1_w1_k1"; then run_case "r1_w1_k1" "1" "1" "10m"; fi
  if should_run_case "r0_w0_k0"; then run_case "r0_w0_k0" "0" "0" "0s"; fi
  if should_run_case "r0_w1_k0"; then run_case "r0_w1_k0" "0" "1" "0s"; fi
  if should_run_case "r0_w0_k1"; then run_case "r0_w0_k1" "0" "0" "10m"; fi
  if should_run_case "r0_w1_k1"; then run_case "r0_w1_k1" "0" "1" "10m"; fi
else
  run_case "baseline" "1" "0" "0s"
fi

print_index_summary

echo "summary=$SUMMARY"