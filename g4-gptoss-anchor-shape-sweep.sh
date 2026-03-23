#!/usr/bin/env bash

set -euo pipefail

# Anchor workload sweep for G4 phase-2/phase-3 evidence collection.
#
# Purpose:
# - Keep a stable observability anchor (`gpt-oss:latest` + ROCBLAS_LAYER=9)
# - Sweep runtime knobs (num_ctx/num_batch/num_thread/keep_alive)
# - Track target GEMM shapes in rocBLAS trace logs for each case

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MODEL="${MODEL:-gpt-oss:latest}"
PROMPT="${PROMPT:-Write a concise technical note about fallback and direct dispatch verification on gfx900 MI25. Include short bullet-like lines in plain text.}"

NUM_PREDICT_LIST="${NUM_PREDICT_LIST:-192}"
NUM_CTX_LIST="${NUM_CTX_LIST:-8192}"
# Baseline anchor batch is fixed to 512.
# Use 1024 explicitly for side-channel shape-shift observations.
NUM_BATCH_LIST="${NUM_BATCH_LIST:-512}"
NUM_THREAD_LIST="${NUM_THREAD_LIST:-}"
KEEP_ALIVE_LIST="${KEEP_ALIVE_LIST:-5m}"
TEMPERATURE="${TEMPERATURE:-0.1}"
RUNS_PER_CASE="${RUNS_PER_CASE:-1}"

ROCBLAS_LAYER="${ROCBLAS_LAYER:-9}"
ROCBLAS_VERBOSE_TENSILE_ERROR="${ROCBLAS_VERBOSE_TENSILE_ERROR:-0}"
ROCBLAS_VERBOSE_HIPBLASLT_ERROR="${ROCBLAS_VERBOSE_HIPBLASLT_ERROR:-0}"

HOST_STRACE="${HOST_STRACE:-127.0.0.1:11534}"
HOST_ROCPROF="${HOST_ROCPROF:-127.0.0.1:11634}"

TARGET_SHAPES="${TARGET_SHAPES:-512x512x2880,4096x512x64,64x512x4096,2880x512x4096,4096x512x2880}"

LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/vega_path_check_logs}"
RAW_LOG_DIR="${RAW_LOG_DIR:-$WORKSPACE_ROOT/vega_path_check_logs_raw}"
mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
MODEL_TAG="$(printf '%s' "$MODEL" | tr '/:' '__')"
TSV="$LOG_DIR/g4_gptoss_anchor_shape_sweep_${MODEL_TAG}_${TS}.tsv"
SUMMARY="$LOG_DIR/g4_gptoss_anchor_shape_sweep_${MODEL_TAG}_${TS}.txt"

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

shape_col_name() {
  local shape="$1"
  local safe
  safe="$(printf '%s' "$shape" | tr 'x' '_' | tr -cd '0-9_')"
  printf 'shape_%s' "$safe"
}

count_shape_hits() {
  local trace_file="$1"
  local shape="$2"
  local m n k
  IFS='x' read -r m n k <<< "$shape"
  if [[ -z "$m" || -z "$n" || -z "$k" || ! -f "$trace_file" ]]; then
    echo 0
    return 0
  fi

  awk -F',' -v m="$m" -v n="$n" -v k="$k" '
    function t(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      f1=t($1); f2=t($2); f4=t($4); f5=t($5); f6=t($6); f7=t($7)
      if ((f1=="rocblas_gemm_ex" || f1=="rocblas_gemm_batched_ex" || f1=="rocblas_sgemm" || f1=="rocblas_hgemm" || f1=="rocblas_dgemm") && f4==m && f5==n && f6==k) {
        c++
      }
      if (f1=="rocblas_internal" && f2=="rocblas_gemm_tensile_backend" && f5==m && f6==n && f7==k) {
        c++
      }
    }
    END { print c+0 }
  ' "$trace_file"
}

list_to_array() {
  local csv="$1"
  local -n out_ref="$2"

  out_ref=()
  if [[ -z "$csv" ]]; then
    out_ref=("")
    return
  fi

  IFS=',' read -r -a out_ref <<< "$csv"
  if [[ "${#out_ref[@]}" -eq 0 ]]; then
    out_ref=("")
  fi

  local i
  for i in "${!out_ref[@]}"; do
    out_ref[$i]="$(echo "${out_ref[$i]}" | xargs)"
  done
}

list_to_array "$NUM_PREDICT_LIST" predict_list
list_to_array "$NUM_CTX_LIST" ctx_list
list_to_array "$NUM_BATCH_LIST" batch_list
list_to_array "$NUM_THREAD_LIST" thread_list
list_to_array "$KEEP_ALIVE_LIST" keepalive_list
list_to_array "$TARGET_SHAPES" target_shape_list

header="timestamp\tcase_id\trun_idx\tmodel\tnum_predict\ttemperature\tnum_ctx\tnum_batch\tnum_thread\tkeep_alive\trocblas_layer\tstatus\tlink_status\tdirect_rocblas_or_tensile_dispatch\tfallback_confirmed\tdispatch_confirmed\trocblas_trace_gemm_lines\tkernel_tensile_like_rows\ttarget_shape_hits_total\tstrace_summary\trocprof_summary\tlink_summary\trocblas_trace_log"
for shape in "${target_shape_list[@]}"; do
  [[ -z "$shape" ]] && continue
  header+="\t$(shape_col_name "$shape")"
done
printf '%b\n' "$header" > "$TSV"

case_id=0
for num_predict in "${predict_list[@]}"; do
  [[ -z "$num_predict" ]] && continue
  for num_ctx in "${ctx_list[@]}"; do
    for num_batch in "${batch_list[@]}"; do
      for num_thread in "${thread_list[@]}"; do
        for keep_alive in "${keepalive_list[@]}"; do
          case_id=$((case_id + 1))

          for run_idx in $(seq 1 "$RUNS_PER_CASE"); do
            set +e
            out="$({
              MODEL="$MODEL" \
              PROMPT="$PROMPT" \
              NUM_PREDICT="$num_predict" \
              TEMPERATURE="$TEMPERATURE" \
              NUM_CTX="$num_ctx" \
              NUM_BATCH="$num_batch" \
              NUM_THREAD="$num_thread" \
              KEEP_ALIVE="$keep_alive" \
              RAW_LOG_DIR="$RAW_LOG_DIR" \
              STRACE_HOST="$HOST_STRACE" \
              ROCPROF_HOST="$HOST_ROCPROF" \
              ROCBLAS_LAYER="$ROCBLAS_LAYER" \
              ROCBLAS_VERBOSE_TENSILE_ERROR="$ROCBLAS_VERBOSE_TENSILE_ERROR" \
              ROCBLAS_VERBOSE_HIPBLASLT_ERROR="$ROCBLAS_VERBOSE_HIPBLASLT_ERROR" \
              "$SCRIPT_DIR/g4-fallback-dispatch-link-check.sh"
            } 2>&1)"
            rc=$?
            set -e

            link_summary="$(printf '%s\n' "$out" | extract_summary_path)"
            if [[ $rc -ne 0 || -z "$link_summary" || ! -f "$link_summary" ]]; then
              row="${TS}\t${case_id}\t${run_idx}\t${MODEL}\t${num_predict}\t${TEMPERATURE}\t${num_ctx}\t${num_batch}\t${num_thread}\t${keep_alive}\t${ROCBLAS_LAYER}\tfailed\t\t0\t0\t0\t0\t0\t0\t\t\t\t"
              for shape in "${target_shape_list[@]}"; do
                [[ -z "$shape" ]] && continue
                row+="\t0"
              done
              printf '%b\n' "$row" >> "$TSV"
              continue
            fi

            strace_summary="$(read_kv "$link_summary" "strace_summary")"
            rocprof_summary="$(read_kv "$link_summary" "rocprof_summary")"
            link_status="$(read_kv "$link_summary" "link_status")"
            direct_dispatch="$(to_int_or_zero "$(read_kv "$link_summary" "direct_rocblas_or_tensile_dispatch")")"
            fallback_confirmed="$(to_int_or_zero "$(read_kv "$link_summary" "fallback_confirmed")")"
            dispatch_confirmed="$(to_int_or_zero "$(read_kv "$link_summary" "dispatch_confirmed")")"
            rocblas_trace_gemm_lines="$(to_int_or_zero "$(read_kv "$link_summary" "rocblas_trace_gemm_lines")")"
            kernel_tensile_like_rows="$(to_int_or_zero "$(read_kv "$link_summary" "kernel_tensile_like_rows")")"

            trace_log=""
            if [[ -n "$strace_summary" && -f "$strace_summary" ]]; then
              trace_log="$(read_kv "$strace_summary" "ROCBLAS_TRACE_LOG")"
            fi

            shape_hits_total=0
            shape_values=()
            for shape in "${target_shape_list[@]}"; do
              [[ -z "$shape" ]] && continue
              hits="$(count_shape_hits "$trace_log" "$shape")"
              hits="$(to_int_or_zero "$hits")"
              shape_hits_total=$((shape_hits_total + hits))
              shape_values+=("$hits")
            done

            row="${TS}\t${case_id}\t${run_idx}\t${MODEL}\t${num_predict}\t${TEMPERATURE}\t${num_ctx}\t${num_batch}\t${num_thread}\t${keep_alive}\t${ROCBLAS_LAYER}\tok\t${link_status}\t${direct_dispatch}\t${fallback_confirmed}\t${dispatch_confirmed}\t${rocblas_trace_gemm_lines}\t${kernel_tensile_like_rows}\t${shape_hits_total}\t${strace_summary}\t${rocprof_summary}\t${link_summary}\t${trace_log}"
            for hits in "${shape_values[@]}"; do
              row+="\t${hits}"
            done
            printf '%b\n' "$row" >> "$TSV"
          done
        done
      done
    done
  done
done

ok_cases="$(awk -F'\t' 'NR>1 && $12=="ok" { c++ } END { print c+0 }' "$TSV")"
failed_cases="$(awk -F'\t' 'NR>1 && $12!="ok" { c++ } END { print c+0 }' "$TSV")"
direct_hits="$(awk -F'\t' 'NR>1 && $12=="ok" && $14+0>0 { c++ } END { print c+0 }' "$TSV")"

best_row="$(awk -F'\t' '
  NR>1 && $12=="ok" {
    score=($19+0)*1000000 + ($14+0)*100000 + ($17+0)*100 + ($18+0)
    if(!seen || score > best_score) {
      seen=1
      best_score=score
      best_row=$0
    }
  }
  END { if(seen) print best_row }
' "$TSV")"

{
  echo "timestamp=$TS"
  echo "model=$MODEL"
  echo "prompt=$PROMPT"
  echo "num_predict_list=$NUM_PREDICT_LIST"
  echo "num_ctx_list=$NUM_CTX_LIST"
  echo "num_batch_list=$NUM_BATCH_LIST"
  echo "num_thread_list=$NUM_THREAD_LIST"
  echo "keep_alive_list=$KEEP_ALIVE_LIST"
  echo "temperature=$TEMPERATURE"
  echo "runs_per_case=$RUNS_PER_CASE"
  echo "rocblas_layer=$ROCBLAS_LAYER"
  echo "rocblas_verbose_tensile_error=$ROCBLAS_VERBOSE_TENSILE_ERROR"
  echo "rocblas_verbose_hipblaslt_error=$ROCBLAS_VERBOSE_HIPBLASLT_ERROR"
  echo "target_shapes=$TARGET_SHAPES"
  echo "raw_log_dir=$RAW_LOG_DIR"
  echo "tsv=$TSV"
  echo
  echo "--- counts ---"
  echo "ok_cases=$ok_cases"
  echo "failed_cases=$failed_cases"
  echo "direct_hits=$direct_hits"
  echo
  echo "--- per-shape totals (ok rows) ---"
  col_index=24
  for shape in "${target_shape_list[@]}"; do
    [[ -z "$shape" ]] && continue
    sum="$(awk -F'\t' -v c="$col_index" 'NR>1 && $12=="ok" { s += ($c+0) } END { print s+0 }' "$TSV")"
    echo "shape_${shape}=$sum"
    col_index=$((col_index + 1))
  done
  echo
  echo "--- top candidate row ---"
  if [[ -n "$best_row" ]]; then
    echo "$best_row"
  else
    echo "none"
  fi
  echo
  echo "--- direct-dispatch rows ---"
  awk -F'\t' 'NR==1 || (NR>1 && $14+0>0)' "$TSV"
} > "$SUMMARY"

echo "summary=$SUMMARY"
