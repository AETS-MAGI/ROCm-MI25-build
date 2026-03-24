#!/usr/bin/env bash

set -euo pipefail

# G4 probe (rocprofv3):
# Capture kernel/runtime traces while serving Ollama on a dedicated port,
# then run one non-stream generate request for dispatch evidence.
#
# Notes:
# - This script is for evidence collection on the canonical main-node workflow.
# - It intentionally keeps the workload short to reduce trace size.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-${1:-tinyllama:latest}}"
PROMPT="${PROMPT:-Generate a short plain-text note about rocprof dispatch tracing on gfx900.}"
NUM_PREDICT="${NUM_PREDICT:-64}"
TEMPERATURE="${TEMPERATURE:-0.1}"
NUM_CTX="${NUM_CTX:-}"
NUM_BATCH="${NUM_BATCH:-}"
NUM_THREAD="${NUM_THREAD:-}"
KEEP_ALIVE="${KEEP_ALIVE:-}"
STREAM="${STREAM:-0}"

HOST="${HOST:-127.0.0.1:11634}"
BASE_URL="http://${HOST}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
CURL_MAX_TIME="${CURL_MAX_TIME:-180}"

OLLAMA_BIN="${OLLAMA_BIN:-$WORKSPACE_ROOT/ollama-src/ollama}"
OLLAMA_MODELS="${OLLAMA_MODELS:-$WORKSPACE_ROOT/ollama-models}"
OLLAMA_LIBRARY_PATH="${OLLAMA_LIBRARY_PATH:-$WORKSPACE_ROOT/ollama-src/build-gfx900/lib/ollama}"
ROCBLAS_TENSILE_LIBPATH="${ROCBLAS_TENSILE_LIBPATH:-$WORKSPACE_ROOT/ROCm-repos_AETS/rocBLAS/build-mi25-gfx900/release/rocblas-install/lib/rocblas/library}"

mkdir -p "$LOG_DIR" "$RAW_LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
PROBE_DIR="$RAW_LOG_DIR/rocprofv3_probe_${MODEL_TAG}_${TS}"
SERVE_OUT="$RAW_LOG_DIR/rocprofv3_serve_stdout_${MODEL_TAG}_${TS}.log"
SERVE_ERR="$RAW_LOG_DIR/rocprofv3_serve_stderr_${MODEL_TAG}_${TS}.log"
GEN_LOG="$RAW_LOG_DIR/rocprofv3_generate_${MODEL_TAG}_${TS}.json"
STREAM_LOG="$RAW_LOG_DIR/rocprofv3_stream_${MODEL_TAG}_${TS}.jsonl"
SUMMARY="$LOG_DIR/rocprofv3_summary_${MODEL_TAG}_${TS}.txt"

mkdir -p "$PROBE_DIR"

cleanup() {
  if [[ -n "${SERVE_PGID:-}" ]] && kill -0 "$SERVE_PGID" >/dev/null 2>&1; then
    kill -TERM -- "-${SERVE_PGID}" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      if ! kill -0 "$SERVE_PGID" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
    kill -KILL -- "-${SERVE_PGID}" >/dev/null 2>&1 || true
    wait "$SERVE_PGID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_api() {
  local i
  for i in $(seq 1 60); do
    if curl -fsS --max-time 3 "$BASE_URL/api/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! command -v rocprofv3 >/dev/null 2>&1; then
  echo "ERROR: rocprofv3 not found" >&2
  exit 1
fi

if [[ ! -x "$OLLAMA_BIN" ]]; then
  echo "ERROR: ollama binary not executable: $OLLAMA_BIN" >&2
  exit 1
fi

export OLLAMA_HOST="$HOST"
export OLLAMA_MODELS
export OLLAMA_LIBRARY_PATH
export LD_LIBRARY_PATH="${OLLAMA_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
export ROCBLAS_TENSILE_LIBPATH
export HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-9.0.0}"
export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0}"

# Launch in a dedicated session; keep PGID for deterministic cleanup.
setsid bash -c \
  "exec rocprofv3 --runtime-trace --kernel-trace -f csv -d '$PROBE_DIR' -- '$OLLAMA_BIN' serve" \
  >"$SERVE_OUT" 2>"$SERVE_ERR" &
SERVE_PGID=$!

if ! wait_for_api; then
  {
    echo "timestamp=$TS"
    echo "result=server_not_ready"
    echo "host=$HOST"
    echo "PROBE_DIR=$PROBE_DIR"
    echo "SERVE_OUT=$SERVE_OUT"
    echo "SERVE_ERR=$SERVE_ERR"
  } > "$SUMMARY"
  echo "summary=$SUMMARY"
  exit 2
fi

stream_chunks=0
stream_response_chunks=0
stream_thinking_chunks=0
stream_json_rows=0
stream_first_token_ns=0
stream_first_token_channel="none"
stream_done_ns=0
ttft_ms_wall=0
stream_total_ms_wall=0
stream_done_reason="unknown"
request_start_ns=0

payload="$(
  jq -nc \
    --arg model "$MODEL" \
    --arg prompt "$PROMPT" \
    --arg np "$NUM_PREDICT" \
    --arg temp "$TEMPERATURE" \
    --arg num_ctx "$NUM_CTX" \
    --arg num_batch "$NUM_BATCH" \
    --arg num_thread "$NUM_THREAD" \
    --arg keep_alive "$KEEP_ALIVE" \
    --arg stream "$STREAM" \
    '{model:$model,prompt:$prompt,stream:($stream=="1")}
    + (if $keep_alive != "" then {keep_alive:$keep_alive} else {} end)
    + {options:
        ({num_predict:($np|tonumber),temperature:($temp|tonumber)}
         + (if $num_ctx != "" then {num_ctx:($num_ctx|tonumber)} else {} end)
         + (if $num_batch != "" then {num_batch:($num_batch|tonumber)} else {} end)
         + (if $num_thread != "" then {num_thread:($num_thread|tonumber)} else {} end)
        )
      }'
)"

if [[ "$STREAM" == "1" ]]; then
  request_start_ns="$(date +%s%N)"
  : > "$STREAM_LOG"
  if ! curl -sS -N --max-time "$CURL_MAX_TIME" "$BASE_URL/api/generate" -d "$payload" \
    | while IFS= read -r line; do
        now_ns="$(date +%s%N)"
        printf '%s\t%s\n' "$now_ns" "$line" >> "$STREAM_LOG"
      done; then
    {
      echo "timestamp=$TS"
      echo "result=generate_failed"
      echo "host=$HOST"
      echo "PROBE_DIR=$PROBE_DIR"
      echo "GEN_LOG=$GEN_LOG"
      echo "STREAM_LOG=$STREAM_LOG"
      echo "SERVE_OUT=$SERVE_OUT"
      echo "SERVE_ERR=$SERVE_ERR"
    } > "$SUMMARY"
    echo "summary=$SUMMARY"
    exit 3
  fi

  stream_metrics_file="$(mktemp)"
  python3 - "$STREAM_LOG" "$GEN_LOG" "$request_start_ns" > "$stream_metrics_file" <<'PY'
import json
import sys

stream_log = sys.argv[1]
gen_log = sys.argv[2]
request_start_ns = int(sys.argv[3])

chunks = 0
response_chunks = 0
thinking_chunks = 0
json_rows = 0
first_token_ns = 0
first_token_channel = "none"
done_ns = 0
done_reason = "unknown"
last_obj = {}

with open(stream_log, "r", encoding="utf-8", errors="replace") as f:
    for row in f:
        row = row.rstrip("\n")
        if not row or "\t" not in row:
            continue
        ts_s, payload = row.split("\t", 1)
        try:
            ts_ns = int(ts_s)
            obj = json.loads(payload)
        except Exception:
            continue

        json_rows += 1
        response = obj.get("response")
        thinking = obj.get("thinking")
        response_nonempty = isinstance(response, str) and response != ""
        thinking_nonempty = isinstance(thinking, str) and thinking != ""

        if response_nonempty:
            response_chunks += 1
            chunks += 1
        if thinking_nonempty:
            thinking_chunks += 1
            chunks += 1
        if first_token_ns == 0 and (response_nonempty or thinking_nonempty):
            first_token_ns = ts_ns
            first_token_channel = "response" if response_nonempty else "thinking"

        if obj.get("done") is True:
            done_ns = ts_ns
            done_reason = str(obj.get("done_reason", "unknown"))
            last_obj = obj
        elif not last_obj:
            last_obj = obj

if not last_obj:
    last_obj = {"done": False}

with open(gen_log, "w", encoding="utf-8") as f:
    json.dump(last_obj, f, ensure_ascii=False)
    f.write("\n")

def ms(delta_ns: int) -> str:
    if delta_ns <= 0:
        return "0"
    return f"{delta_ns / 1_000_000.0:.3f}"

ttft_ms = ms(first_token_ns - request_start_ns) if first_token_ns > 0 else "0"
total_ms = ms(done_ns - request_start_ns) if done_ns > 0 else "0"

print(f"stream_chunks={chunks}")
print(f"stream_response_chunks={response_chunks}")
print(f"stream_thinking_chunks={thinking_chunks}")
print(f"stream_json_rows={json_rows}")
print(f"stream_first_token_ns={first_token_ns}")
print(f"stream_first_token_channel={first_token_channel}")
print(f"stream_done_ns={done_ns}")
print(f"ttft_ms_wall={ttft_ms}")
print(f"stream_total_ms_wall={total_ms}")
print(f"stream_done_reason={done_reason}")
PY
  # shellcheck disable=SC1090
  source "$stream_metrics_file"
  rm -f "$stream_metrics_file"
else
  if ! curl -sS --max-time "$CURL_MAX_TIME" "$BASE_URL/api/generate" \
    -d "$payload" \
    > "$GEN_LOG"; then
    {
      echo "timestamp=$TS"
      echo "result=generate_failed"
      echo "host=$HOST"
      echo "PROBE_DIR=$PROBE_DIR"
      echo "GEN_LOG=$GEN_LOG"
      echo "SERVE_OUT=$SERVE_OUT"
      echo "SERVE_ERR=$SERVE_ERR"
    } > "$SUMMARY"
    echo "summary=$SUMMARY"
    exit 3
  fi
fi

sleep 2
cleanup

trace_file_count="$(find "$PROBE_DIR" -type f | wc -l | tr -d ' ')"
csv_file_count="$(find "$PROBE_DIR" -type f -name '*.csv' | wc -l | tr -d ' ')"
dispatch_rows="$(rg -n -i "KERNEL_DISPATCH|dispatch" "$PROBE_DIR" --glob '*.csv' | wc -l | tr -d ' ' || true)"
tensile_rows="$(rg -n -i "tensile|gemm|rocblas|hipblas" "$PROBE_DIR" --glob '*.csv' | wc -l | tr -d ' ' || true)"
kernel_trace_file="$(find "$PROBE_DIR" -type f -name '*kernel_trace.csv' | head -n 1 || true)"

kernel_dispatch_rows=0
kernel_mul_mat_q_rows=0
kernel_mul_mat_vec_rows=0
kernel_flash_attn_rows=0
kernel_quantize_rows=0
kernel_copy_rows=0
kernel_tensile_like_rows=0
if [[ -n "$kernel_trace_file" && -f "$kernel_trace_file" ]]; then
  {
    set +o pipefail
    kernel_dispatch_rows="$(rg -n "\"KERNEL_DISPATCH\"" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_mul_mat_q_rows="$(rg -n "mul_mat_q<" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_mul_mat_vec_rows="$(rg -n "mul_mat_vec_q<" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_flash_attn_rows="$(rg -n "flash_attn" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_quantize_rows="$(rg -n "quantize_" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_copy_rows="$(rg -n "__amd_rocclr_copyBuffer|fillBufferAligned" "$kernel_trace_file" | wc -l | tr -d ' ')"
    kernel_tensile_like_rows="$(rg -n -i "tensile|contraction|cijk|rocblas|gemm_ex|gemm" "$kernel_trace_file" | wc -l | tr -d ' ')"
    set -o pipefail
  }
fi

prompt_eval_duration_ns="$(jq -r '.prompt_eval_duration // 0' "$GEN_LOG" 2>/dev/null || echo 0)"
eval_duration_ns="$(jq -r '.eval_duration // 0' "$GEN_LOG" 2>/dev/null || echo 0)"

phase_split_status_proxy="unavailable"
phase_split_method="none"
phase_boundary_ts_proxy=0
prefill_kernel_dispatch_rows=0
decode_kernel_dispatch_rows=0
prefill_kernel_tensile_like_rows=0
decode_kernel_tensile_like_rows=0

if [[ -n "$kernel_trace_file" && -f "$kernel_trace_file" && "$prompt_eval_duration_ns" =~ ^[0-9]+$ && "$prompt_eval_duration_ns" -gt 0 ]]; then
  phase_metrics_file="$(mktemp)"
  python3 - "$kernel_trace_file" "$prompt_eval_duration_ns" > "$phase_metrics_file" <<'PY'
import csv
import re
import sys

kernel_csv = sys.argv[1]
prompt_eval_duration = int(sys.argv[2])

rows = []
with open(kernel_csv, "r", encoding="utf-8", errors="replace", newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        try:
            start = int(row.get("Start_Timestamp", "0") or "0")
        except ValueError:
            start = 0
        if start <= 0:
            continue
        kind = str(row.get("Kind", ""))
        name = str(row.get("Kernel_Name", ""))
        rows.append((start, kind, name))

if not rows:
    print("phase_split_status_proxy=kernel_trace_empty")
    print("phase_split_method=none")
    print("phase_boundary_ts_proxy=0")
    print("prefill_kernel_dispatch_rows=0")
    print("decode_kernel_dispatch_rows=0")
    print("prefill_kernel_tensile_like_rows=0")
    print("decode_kernel_tensile_like_rows=0")
    raise SystemExit(0)

rows.sort(key=lambda x: x[0])
min_start = rows[0][0]
boundary = min_start + prompt_eval_duration

tensile_pat = re.compile(r"tensile|contraction|cijk|rocblas|gemm_ex|gemm", re.IGNORECASE)

prefill_dispatch = 0
decode_dispatch = 0
prefill_tensile = 0
decode_tensile = 0

for start, kind, name in rows:
    in_prefill = start <= boundary
    is_dispatch = (kind == "KERNEL_DISPATCH")
    is_tensile = tensile_pat.search(name) is not None
    if in_prefill:
        if is_dispatch:
            prefill_dispatch += 1
        if is_tensile:
            prefill_tensile += 1
    else:
        if is_dispatch:
            decode_dispatch += 1
        if is_tensile:
            decode_tensile += 1

status = "prefill_dominant_signature" if decode_tensile == 0 else "decode_signature_detected"
print(f"phase_split_status_proxy={status}")
print("phase_split_method=kernel_start_min_plus_prompt_eval_duration")
print(f"phase_boundary_ts_proxy={boundary}")
print(f"prefill_kernel_dispatch_rows={prefill_dispatch}")
print(f"decode_kernel_dispatch_rows={decode_dispatch}")
print(f"prefill_kernel_tensile_like_rows={prefill_tensile}")
print(f"decode_kernel_tensile_like_rows={decode_tensile}")
PY
  # shellcheck disable=SC1090
  source "$phase_metrics_file"
  rm -f "$phase_metrics_file"
fi

{
  echo "timestamp=$TS"
  echo "host=$HOST"
  echo "model=$MODEL"
  echo "num_predict=$NUM_PREDICT"
  echo "temperature=$TEMPERATURE"
  echo "num_ctx=$NUM_CTX"
  echo "num_batch=$NUM_BATCH"
  echo "num_thread=$NUM_THREAD"
  echo "keep_alive=$KEEP_ALIVE"
  echo "RAW_LOG_DIR=$RAW_LOG_DIR"
  echo "STREAM=$STREAM"
  echo "OLLAMA_LIBRARY_PATH=$OLLAMA_LIBRARY_PATH"
  echo "ROCBLAS_TENSILE_LIBPATH=$ROCBLAS_TENSILE_LIBPATH"
  echo "PROBE_DIR=$PROBE_DIR"
  echo "GEN_LOG=$GEN_LOG"
  if [[ "$STREAM" == "1" ]]; then
    echo "STREAM_LOG=$STREAM_LOG"
  fi
  echo "SERVE_OUT=$SERVE_OUT"
  echo "SERVE_ERR=$SERVE_ERR"
  echo "request_start_ns=$request_start_ns"
  echo "stream_chunks=$stream_chunks"
  echo "stream_response_chunks=$stream_response_chunks"
  echo "stream_thinking_chunks=$stream_thinking_chunks"
  echo "stream_json_rows=$stream_json_rows"
  echo "stream_first_token_ns=$stream_first_token_ns"
  echo "stream_first_token_channel=$stream_first_token_channel"
  echo "stream_done_ns=$stream_done_ns"
  echo "ttft_ms_wall=$ttft_ms_wall"
  echo "stream_total_ms_wall=$stream_total_ms_wall"
  echo "stream_done_reason=$stream_done_reason"
  echo "prompt_eval_duration_ns=$prompt_eval_duration_ns"
  echo "eval_duration_ns=$eval_duration_ns"
  echo "phase_split_status_proxy=$phase_split_status_proxy"
  echo "phase_split_method=$phase_split_method"
  echo "phase_boundary_ts_proxy=$phase_boundary_ts_proxy"
  echo "prefill_kernel_dispatch_rows=$prefill_kernel_dispatch_rows"
  echo "decode_kernel_dispatch_rows=$decode_kernel_dispatch_rows"
  echo "prefill_kernel_tensile_like_rows=$prefill_kernel_tensile_like_rows"
  echo "decode_kernel_tensile_like_rows=$decode_kernel_tensile_like_rows"
  echo
  echo "--- generate result ---"
  jq -r '.model,.done,.done_reason,.total_duration,.load_duration,.prompt_eval_count,.eval_count' "$GEN_LOG" 2>/dev/null || cat "$GEN_LOG"
  echo
  echo "--- rocprof output counts ---"
  echo "trace_file_count=${trace_file_count}"
  echo "csv_file_count=${csv_file_count}"
  echo "dispatch_rows=${dispatch_rows}"
  echo "tensile_or_gemm_rows=${tensile_rows}"
  if [[ -n "$kernel_trace_file" ]]; then
    echo "kernel_trace_file=${kernel_trace_file}"
    echo "kernel_dispatch_rows=${kernel_dispatch_rows}"
    echo "kernel_mul_mat_q_rows=${kernel_mul_mat_q_rows}"
    echo "kernel_mul_mat_vec_rows=${kernel_mul_mat_vec_rows}"
    echo "kernel_flash_attn_rows=${kernel_flash_attn_rows}"
    echo "kernel_quantize_rows=${kernel_quantize_rows}"
    echo "kernel_copy_rows=${kernel_copy_rows}"
    echo "kernel_tensile_like_rows=${kernel_tensile_like_rows}"
  fi
  echo
  echo "--- rocprof files ---"
  find "$PROBE_DIR" -maxdepth 4 -type f | sort
  if [[ -n "$kernel_trace_file" && -f "$kernel_trace_file" ]]; then
    echo
    echo "--- top kernel names (dispatch rows) ---"
    awk 'NR>1 && /"KERNEL_DISPATCH"/ { if (match($0, /,[0-9]+,"([^"]+)",[0-9]+,/, a)) c[a[1]]++ } END { for (k in c) print c[k] "\t" k }' "$kernel_trace_file" | sort -nr | head -n 30
  fi
  echo
  echo "--- sample matches (dispatch/tensile/gemm) ---"
  {
    set +o pipefail
    rg -n -i "KERNEL_DISPATCH|dispatch|tensile|gemm|rocblas|hipblas" "$PROBE_DIR" --glob '*.csv' | head -n 80 || true
    set -o pipefail
  }
} > "$SUMMARY"

echo "summary=$SUMMARY"
