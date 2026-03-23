#!/usr/bin/env bash

set -euo pipefail

# Workload-condition sweep for direct rocBLAS/Tensile dispatch evidence.
# It orchestrates g4-fallback-dispatch-link-check.sh across model/prompt/predict grids.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL_LIST="${MODEL_LIST:-tinyllama:latest,qwen2.5:7b}"
NUM_PREDICT_LIST="${NUM_PREDICT_LIST:-64,256}"
PROMPT_PROFILE_LIST="${PROMPT_PROFILE_LIST:-short,long}"

TEMPERATURE="${TEMPERATURE:-0.1}"
RUNS_PER_CASE="${RUNS_PER_CASE:-1}"
HOST_STRACE="${HOST_STRACE:-127.0.0.1:11534}"
HOST_ROCPROF="${HOST_ROCPROF:-127.0.0.1:11634}"
NUM_CTX="${NUM_CTX:-}"
NUM_BATCH="${NUM_BATCH:-}"
NUM_THREAD="${NUM_THREAD:-}"
KEEP_ALIVE="${KEEP_ALIVE:-}"

# Keep defaults aligned with current observability baseline.
ROCBLAS_LAYER="${ROCBLAS_LAYER:-9}"
ROCBLAS_VERBOSE_TENSILE_ERROR="${ROCBLAS_VERBOSE_TENSILE_ERROR:-0}"
ROCBLAS_VERBOSE_HIPBLASLT_ERROR="${ROCBLAS_VERBOSE_HIPBLASLT_ERROR:-0}"

LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
TSV="$LOG_DIR/g4_workload_path_sweep_${TS}.tsv"
SUMMARY="$LOG_DIR/g4_workload_path_sweep_${TS}.txt"

prompt_for_profile() {
  local profile="$1"
  case "$profile" in
    short)
      cat <<'EOF'
Write a very short note about ROCm on MI25.
EOF
      ;;
    long)
      cat <<'EOF'
You are writing a detailed technical note. Explain fallback path evidence, kernel dispatch evidence,
and why direct rocBLAS/Tensile dispatch naming can remain hidden in quantized GGUF workloads.
Include at least five concrete points with concise wording.
EOF
      ;;
    code)
      cat <<'EOF'
Generate pseudocode for a benchmarking loop that compares model/prompt/num_predict settings and records
ttft, tokens-per-second, and fallback-vs-dispatch evidence labels.
EOF
      ;;
    math)
      cat <<'EOF'
Provide a concise derivation-style explanation of throughput estimation from eval_count and eval_duration,
and discuss caveats under warm/cold runs.
EOF
      ;;
    *)
      # Pass through custom literal profile string as prompt.
      printf '%s\n' "$profile"
      ;;
  esac
}

read_kv() {
  local file="$1"
  local key="$2"
  if [[ ! -f "$file" ]]; then
    echo ""
    return 0
  fi
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file"
}

to_int_or_zero() {
  local v="${1:-}"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
  else
    echo "0"
  fi
}

extract_summary_path() {
  awk -F= '/^summary=/{print $2}' | tail -n 1
}

json_int() {
  local json_file="$1"
  local key="$2"
  if [[ -f "$json_file" ]]; then
    jq -r --arg k "$key" '.[$k] // 0' "$json_file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

{
  printf "timestamp\tcase_id\tmodel\tprompt_profile\tnum_predict\trun_idx\tstatus\tlink_status\tdirect_rocblas_or_tensile_dispatch\tfallback_confirmed\tdispatch_confirmed\trocblas_trace_gemm_lines\tkernel_tensile_like_rows\tkernel_dispatch_rows\tkernel_mul_mat_q_rows\tkernel_mul_mat_vec_rows\tkernel_flash_attn_rows\tkernel_quantize_rows\tprompt_eval_count\teval_count\ttotal_duration_ns\tload_duration_ns\tstrace_summary\trocprof_summary\tlink_summary\n"
} > "$TSV"

IFS=',' read -r -a models <<< "$MODEL_LIST"
IFS=',' read -r -a predicts <<< "$NUM_PREDICT_LIST"
IFS=',' read -r -a profiles <<< "$PROMPT_PROFILE_LIST"

case_id=0
for model in "${models[@]}"; do
  model="$(echo "$model" | xargs)"
  [[ -z "$model" ]] && continue

  for predict in "${predicts[@]}"; do
    predict="$(echo "$predict" | xargs)"
    [[ -z "$predict" ]] && continue

    for profile in "${profiles[@]}"; do
      profile="$(echo "$profile" | xargs)"
      [[ -z "$profile" ]] && continue

      prompt="$(prompt_for_profile "$profile")"
      case_id=$((case_id + 1))

      for run_idx in $(seq 1 "$RUNS_PER_CASE"); do
        set +e
        out="$(
          MODEL="$model" \
          NUM_PREDICT="$predict" \
          PROMPT="$prompt" \
          TEMPERATURE="$TEMPERATURE" \
          NUM_CTX="$NUM_CTX" \
          NUM_BATCH="$NUM_BATCH" \
          NUM_THREAD="$NUM_THREAD" \
          KEEP_ALIVE="$KEEP_ALIVE" \
          RAW_LOG_DIR="$RAW_LOG_DIR" \
          STRACE_HOST="$HOST_STRACE" \
          ROCPROF_HOST="$HOST_ROCPROF" \
          ROCBLAS_LAYER="$ROCBLAS_LAYER" \
          ROCBLAS_VERBOSE_TENSILE_ERROR="$ROCBLAS_VERBOSE_TENSILE_ERROR" \
          ROCBLAS_VERBOSE_HIPBLASLT_ERROR="$ROCBLAS_VERBOSE_HIPBLASLT_ERROR" \
          "$SCRIPT_DIR/g4-fallback-dispatch-link-check.sh" 2>&1
        )"
        rc=$?
        set -e

        link_summary="$(printf '%s\n' "$out" | extract_summary_path)"
        status="ok"
        if [[ $rc -ne 0 || -z "$link_summary" || ! -f "$link_summary" ]]; then
          status="failed"
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t\t\t\n" \
            "$TS" "$case_id" "$model" "$profile" "$predict" "$run_idx" "$status" >> "$TSV"
          continue
        fi

        strace_summary="$(read_kv "$link_summary" "strace_summary")"
        rocprof_summary="$(read_kv "$link_summary" "rocprof_summary")"

        link_status="$(read_kv "$link_summary" "link_status")"
        direct="$(to_int_or_zero "$(read_kv "$link_summary" "direct_rocblas_or_tensile_dispatch")")"
        fallback_confirmed="$(to_int_or_zero "$(read_kv "$link_summary" "fallback_confirmed")")"
        dispatch_confirmed="$(to_int_or_zero "$(read_kv "$link_summary" "dispatch_confirmed")")"
        rocblas_trace_gemm_lines="$(to_int_or_zero "$(read_kv "$link_summary" "rocblas_trace_gemm_lines")")"
        kernel_tensile_like_rows="$(to_int_or_zero "$(read_kv "$link_summary" "kernel_tensile_like_rows")")"
        kernel_dispatch_rows="$(to_int_or_zero "$(read_kv "$link_summary" "kernel_dispatch_rows")")"
        kernel_mul_mat_q_rows="$(to_int_or_zero "$(read_kv "$link_summary" "kernel_mul_mat_q_rows")")"
        kernel_mul_mat_vec_rows="$(to_int_or_zero "$(read_kv "$link_summary" "kernel_mul_mat_vec_rows")")"
        kernel_flash_attn_rows="$(to_int_or_zero "$(read_kv "$link_summary" "kernel_flash_attn_rows")")"
        kernel_quantize_rows="$(to_int_or_zero "$(read_kv "$link_summary" "kernel_quantize_rows")")"

        gen_log=""
        if [[ -n "$strace_summary" && -f "$strace_summary" ]]; then
          gen_log="$(read_kv "$strace_summary" "GEN_LOG")"
        fi

        prompt_eval_count="$(to_int_or_zero "$(json_int "$gen_log" "prompt_eval_count")")"
        eval_count="$(to_int_or_zero "$(json_int "$gen_log" "eval_count")")"
        total_duration_ns="$(to_int_or_zero "$(json_int "$gen_log" "total_duration")")"
        load_duration_ns="$(to_int_or_zero "$(json_int "$gen_log" "load_duration")")"

        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
          "$TS" "$case_id" "$model" "$profile" "$predict" "$run_idx" "$status" "$link_status" \
          "$direct" "$fallback_confirmed" "$dispatch_confirmed" "$rocblas_trace_gemm_lines" \
          "$kernel_tensile_like_rows" "$kernel_dispatch_rows" "$kernel_mul_mat_q_rows" \
          "$kernel_mul_mat_vec_rows" "$kernel_flash_attn_rows" "$kernel_quantize_rows" \
          "$prompt_eval_count" "$eval_count" "$total_duration_ns" "$load_duration_ns" \
          "$strace_summary" "$rocprof_summary" "$link_summary" >> "$TSV"
      done
    done
  done
done

direct_hits="$(awk -F'\t' 'NR>1 && $7=="ok" && $9+0>0 { c++ } END{ print c+0 }' "$TSV")"
ok_cases="$(awk -F'\t' 'NR>1 && $7=="ok" { c++ } END{ print c+0 }' "$TSV")"
failed_cases="$(awk -F'\t' 'NR>1 && $7!="ok" { c++ } END{ print c+0 }' "$TSV")"

best_row="$(awk -F'\t' '
  NR>1 && $7=="ok" {
    # prioritize direct hit -> gemm lines -> tensile-like rows -> dispatch volume
    score=($9+0)*1000000 + ($12+0)*100000 + ($13+0)*1000 + ($14+0)
    if(!seen || score>best) {
      seen=1
      best=score
      row=$0
    }
  }
  END { if(seen) print row }' "$TSV")"

{
  echo "timestamp=$TS"
  echo "workspace_root=$WORKSPACE_ROOT"
  echo "model_list=$MODEL_LIST"
  echo "num_predict_list=$NUM_PREDICT_LIST"
  echo "prompt_profile_list=$PROMPT_PROFILE_LIST"
  echo "runs_per_case=$RUNS_PER_CASE"
  echo "temperature=$TEMPERATURE"
  echo "num_ctx=$NUM_CTX"
  echo "num_batch=$NUM_BATCH"
  echo "num_thread=$NUM_THREAD"
  echo "keep_alive=$KEEP_ALIVE"
  echo "raw_log_dir=$RAW_LOG_DIR"
  echo "rocblas_layer=$ROCBLAS_LAYER"
  echo "rocblas_verbose_tensile_error=$ROCBLAS_VERBOSE_TENSILE_ERROR"
  echo "rocblas_verbose_hipblaslt_error=$ROCBLAS_VERBOSE_HIPBLASLT_ERROR"
  echo "tsv=$TSV"
  echo
  echo "--- counts ---"
  echo "ok_cases=$ok_cases"
  echo "failed_cases=$failed_cases"
  echo "direct_hits=$direct_hits"
  echo
  echo "--- top candidate row ---"
  if [[ -n "$best_row" ]]; then
    echo "$best_row"
  else
    echo "none"
  fi
  echo
  echo "--- direct-hit rows ---"
  awk -F'\t' 'NR==1 || (NR>1 && $9+0>0)' "$TSV"
} > "$SUMMARY"

echo "summary=$SUMMARY"
