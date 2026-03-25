#!/usr/bin/env bash

set -euo pipefail

# G4 probe:
# Confirm runtime fallback path usage by tracing openat/openat2 and
# verifying TensileLibrary_*_fallback.{dat,hsaco} access on gfx900/MI25.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-${1:-tinyllama:latest}}"
PROMPT="${PROMPT:-Generate a 160-word plain-text note about ROCm fallback verification on gfx900.}"
NUM_PREDICT="${NUM_PREDICT:-200}"
TEMPERATURE="${TEMPERATURE:-0.1}"
NUM_CTX="${NUM_CTX:-}"
NUM_BATCH="${NUM_BATCH:-}"
NUM_THREAD="${NUM_THREAD:-}"
KEEP_ALIVE="${KEEP_ALIVE:-}"
STREAM="${STREAM:-0}"
CURL_MAX_TIME="${CURL_MAX_TIME:-300}"

HOST="${HOST:-127.0.0.1:11534}"
BASE_URL="http://${HOST}"
LOG_DIR="${LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw/summaries}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"

OLLAMA_BIN="${OLLAMA_BIN:-$WORKSPACE_ROOT/ollama-src/ollama}"
OLLAMA_MODELS="${OLLAMA_MODELS:-$WORKSPACE_ROOT/ollama-models}"
OLLAMA_LIBRARY_PATH="${OLLAMA_LIBRARY_PATH:-$WORKSPACE_ROOT/ollama-src/build-gfx900/lib/ollama}"
ROCBLAS_TENSILE_LIBPATH="${ROCBLAS_TENSILE_LIBPATH:-$WORKSPACE_ROOT/ROCm-repos_AETS/rocBLAS/build-mi25-gfx900/release/rocblas-install/lib/rocblas/library}"
STRACE_TIMESTAMP="${STRACE_TIMESTAMP:-1}"
PROBE_ROCBLAS_LOG="${PROBE_ROCBLAS_LOG:-0}"
# 9 = trace(1) + internal(8): best observability/overhead balance for
# backend-path debugging on current GGUF runs.
ROCBLAS_LAYER="${ROCBLAS_LAYER:-9}"

mkdir -p "$LOG_DIR" "$RAW_LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
STRACE_PREFIX="$RAW_LOG_DIR/g4_strace_openat_${MODEL_TAG}_${TS}.log"
SERVE_OUT="$RAW_LOG_DIR/g4_serve_stdout_${MODEL_TAG}_${TS}.log"
SERVE_ERR="$RAW_LOG_DIR/g4_serve_stderr_${MODEL_TAG}_${TS}.log"
GEN_LOG="$RAW_LOG_DIR/g4_generate_${MODEL_TAG}_${TS}.json"
STREAM_LOG="$RAW_LOG_DIR/g4_stream_${MODEL_TAG}_${TS}.jsonl"
SUMMARY="$LOG_DIR/g4_summary_${MODEL_TAG}_${TS}.txt"
ROCBLAS_TRACE_LOG="${ROCBLAS_LOG_TRACE_PATH:-$RAW_LOG_DIR/g4_rocblas_trace_${MODEL_TAG}_${TS}.log}"
ROCBLAS_BENCH_LOG="${ROCBLAS_LOG_BENCH_PATH:-$RAW_LOG_DIR/g4_rocblas_bench_${MODEL_TAG}_${TS}.log}"
ROCBLAS_PROFILE_LOG="${ROCBLAS_LOG_PROFILE_PATH:-$RAW_LOG_DIR/g4_rocblas_profile_${MODEL_TAG}_${TS}.log}"

if ! command -v strace >/dev/null 2>&1; then
  echo "ERROR: strace is required but not found" >&2
  exit 1
fi

if [[ ! -x "$OLLAMA_BIN" ]]; then
  echo "ERROR: ollama binary not executable: $OLLAMA_BIN" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${SERVE_PID:-}" ]] && kill -0 "$SERVE_PID" >/dev/null 2>&1; then
    # Kill the whole process group (strace + traced ollama serve + runner children).
    kill -TERM -- "-${SERVE_PID}" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      if ! kill -0 "$SERVE_PID" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
    kill -KILL -- "-${SERVE_PID}" >/dev/null 2>&1 || true
    wait "$SERVE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_api() {
  local i
  for i in $(seq 1 60); do
    if curl -fsS "$BASE_URL/api/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

export OLLAMA_HOST="$HOST"
export OLLAMA_MODELS
export OLLAMA_LIBRARY_PATH
export LD_LIBRARY_PATH="${OLLAMA_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
export ROCBLAS_TENSILE_LIBPATH
export HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-9.0.0}"
export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0}"
if [[ "$PROBE_ROCBLAS_LOG" == "1" ]]; then
  export ROCBLAS_LAYER
  export ROCBLAS_LOG_TRACE_PATH="$ROCBLAS_TRACE_LOG"
  export ROCBLAS_LOG_BENCH_PATH="$ROCBLAS_BENCH_LOG"
  export ROCBLAS_LOG_PROFILE_PATH="$ROCBLAS_PROFILE_LOG"
  rm -f "$ROCBLAS_TRACE_LOG" "$ROCBLAS_BENCH_LOG" "$ROCBLAS_PROFILE_LOG"
fi

STRACE_TIME_ARGS=()
if [[ "$STRACE_TIMESTAMP" == "1" ]]; then
  STRACE_TIME_ARGS=(-tt)
fi

# Run probe server in a dedicated process group so cleanup is deterministic.
setsid strace -ff -s 300 "${STRACE_TIME_ARGS[@]}" -e trace=openat,openat2 -o "$STRACE_PREFIX" \
  "$OLLAMA_BIN" serve >"$SERVE_OUT" 2>"$SERVE_ERR" &
SERVE_PID=$!

if ! wait_for_api; then
  {
    echo "timestamp=$TS"
    echo "result=server_not_ready"
    echo "host=$HOST"
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
      echo "GEN_LOG=$GEN_LOG"
      echo "STREAM_LOG=$STREAM_LOG"
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
        if not row:
            continue
        if "\t" not in row:
            continue
        ts_s, payload = row.split("\t", 1)
        try:
            ts_ns = int(ts_s)
        except ValueError:
            continue
        try:
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
  curl -sS --max-time "$CURL_MAX_TIME" "$BASE_URL/api/generate" \
    -d "$payload" \
    > "$GEN_LOG"
fi

sleep 2

cleanup

count_in_strace() {
  local pattern="$1"
  {
    set +o pipefail
    rg -n "$pattern" "${STRACE_PREFIX}"* 2>/dev/null | wc -l | tr -d ' '
    set -o pipefail
  }
}

fallback_dat_count="$(count_in_strace "TensileLibrary_.*_fallback\\.dat")"
fallback_hsaco_count="$(count_in_strace "TensileLibrary_.*_fallback_gfx900\\.hsaco")"
hip_backend_count="$(count_in_strace "libggml-hip\\.so")"
rocblas_trace_lines=0
rocblas_trace_gemm_lines=0
rocblas_trace_handle_lines=0
if [[ "$PROBE_ROCBLAS_LOG" == "1" && -f "$ROCBLAS_TRACE_LOG" ]]; then
  rocblas_trace_lines="$(wc -l < "$ROCBLAS_TRACE_LOG" | tr -d ' ')"
  {
    set +o pipefail
    rocblas_trace_gemm_lines="$(rg -n -i "gemm|matmul|tensile" "$ROCBLAS_TRACE_LOG" | wc -l | tr -d ' ')"
    rocblas_trace_handle_lines="$(rg -n "rocblas_create_handle" "$ROCBLAS_TRACE_LOG" | wc -l | tr -d ' ')"
    set -o pipefail
  }
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
  echo "OLLAMA_LIBRARY_PATH=$OLLAMA_LIBRARY_PATH"
  echo "ROCBLAS_TENSILE_LIBPATH=$ROCBLAS_TENSILE_LIBPATH"
  echo "GEN_LOG=$GEN_LOG"
  echo "STREAM=$STREAM"
  if [[ "$STREAM" == "1" ]]; then
    echo "STREAM_LOG=$STREAM_LOG"
  fi
  echo "STRACE_PREFIX=$STRACE_PREFIX"
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
  echo "strace_timestamp=$STRACE_TIMESTAMP"
  echo "probe_rocblas_log=$PROBE_ROCBLAS_LOG"
  if [[ "$PROBE_ROCBLAS_LOG" == "1" ]]; then
    echo "ROCBLAS_TRACE_LOG=$ROCBLAS_TRACE_LOG"
    echo "ROCBLAS_BENCH_LOG=$ROCBLAS_BENCH_LOG"
    echo "ROCBLAS_PROFILE_LOG=$ROCBLAS_PROFILE_LOG"
  fi
  echo
  echo "--- generate result ---"
  jq -r '.model,.done,.done_reason,.total_duration,.load_duration,.prompt_eval_count,.eval_count' "$GEN_LOG" 2>/dev/null || cat "$GEN_LOG"
  echo
  echo "--- evidence counts ---"
  echo "libggml_hip_openat=${hip_backend_count}"
  echo "fallback_dat_openat=${fallback_dat_count}"
  echo "fallback_hsaco_openat=${fallback_hsaco_count}"
  if [[ "$PROBE_ROCBLAS_LOG" == "1" ]]; then
    echo "rocblas_trace_lines=${rocblas_trace_lines}"
    echo "rocblas_trace_handle_lines=${rocblas_trace_handle_lines}"
    echo "rocblas_trace_gemm_lines=${rocblas_trace_gemm_lines}"
  fi
  echo
  echo "--- evidence sample: backend load ---"
  {
    set +o pipefail
    rg -n "libggml-hip\\.so|librocblas\\.so\\.5" "${STRACE_PREFIX}"* | head -n 20 || true
    set -o pipefail
  }
  echo
  echo "--- evidence sample: fallback .dat ---"
  {
    set +o pipefail
    rg -n "TensileLibrary_.*_fallback\\.dat" "${STRACE_PREFIX}"* | head -n 20 || true
    set -o pipefail
  }
  echo
  echo "--- evidence sample: fallback .hsaco ---"
  {
    set +o pipefail
    rg -n "TensileLibrary_.*_fallback_gfx900\\.hsaco" "${STRACE_PREFIX}"* | head -n 20 || true
    set -o pipefail
  }
  if [[ "$PROBE_ROCBLAS_LOG" == "1" ]]; then
    echo
    echo "--- evidence sample: rocBLAS trace ---"
    {
      set +o pipefail
      sed -n '1,40p' "$ROCBLAS_TRACE_LOG" 2>/dev/null || true
      set -o pipefail
    }
  fi
} > "$SUMMARY"

echo "summary=$SUMMARY"
