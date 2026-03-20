#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OLLAMA_BIN_DEFAULT="$PROJECT_ROOT/ollama-src/ollama"
MODELS_DIR_DEFAULT="$PROJECT_ROOT/ollama-models"
LIB_DIR_DEFAULT="$PROJECT_ROOT/ollama-src/build/lib/ollama"
ROCBLAS_LIB_DEFAULT="$PROJECT_ROOT/ROCm-repos_AETS/rocBLAS/build-mi25-gfx900/release/rocblas-install/lib/rocblas/library"
HOST_DEFAULT="127.0.0.1:11434"
PID_FILE_DEFAULT="/tmp/ollama-manual.pid"
LOG_FILE_DEFAULT="/tmp/ollama-manual.log"

OLLAMA_BIN="${OLLAMA_BIN:-$OLLAMA_BIN_DEFAULT}"
MODELS_DIR="${OLLAMA_MODELS:-$MODELS_DIR_DEFAULT}"
LIB_DIR="${OLLAMA_LIBRARY_PATH:-$LIB_DIR_DEFAULT}"
ROCBLAS_LIB="${ROCBLAS_TENSILE_LIBPATH:-$ROCBLAS_LIB_DEFAULT}"
HOST="${OLLAMA_HOST:-$HOST_DEFAULT}"
HIP_DEVICES="${HIP_VISIBLE_DEVICES:-0}"
HSA_GFX="${HSA_OVERRIDE_GFX_VERSION:-9.0.0}"
PID_FILE="${OLLAMA_MANUAL_PID_FILE:-$PID_FILE_DEFAULT}"
LOG_FILE="${OLLAMA_MANUAL_LOG_FILE:-$LOG_FILE_DEFAULT}"

usage() {
  cat <<'EOF'
Usage:
  ./ollama-manual.sh start
  ./ollama-manual.sh stop
  ./ollama-manual.sh restart
  ./ollama-manual.sh status
  ./ollama-manual.sh run <model> [prompt...]

Notes:
  - start: run manual "ollama serve" with fixed ROCm and model-path env.
  - run: if no prompt is provided, launches interactive ollama run.
  - service and manual serve should not run together on same host/port.

Main env defaults:
  OLLAMA_BIN                /home/$USER/ROCm-project/ollama-src/ollama
  OLLAMA_MODELS             /home/$USER/ROCm-project/ollama-models
  OLLAMA_LIBRARY_PATH       /home/$USER/ROCm-project/ollama-src/build/lib/ollama
  ROCBLAS_TENSILE_LIBPATH   .../ROCm-repos_AETS/rocBLAS/.../rocblas/library
  OLLAMA_HOST               127.0.0.1:11434
EOF
}

require_file() {
  local path="$1"
  local kind="$2"
  if [[ ! -e "$path" ]]; then
    echo "missing $kind: $path" >&2
    exit 1
  fi
}

running_pid() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ps -p "$pid" -o comm= 2>/dev/null | rg -q '^ollama$'; then
      echo "$pid"
      return 0
    fi
  fi

  local p
  p="$(pgrep -f '^.*ollama serve$' | head -n1 || true)"
  if [[ -n "$p" ]]; then
    echo "$p"
    return 0
  fi

  return 1
}

print_env_summary() {
  cat <<EOF
OLLAMA_BIN=$OLLAMA_BIN
OLLAMA_MODELS=$MODELS_DIR
OLLAMA_LIBRARY_PATH=$LIB_DIR
ROCBLAS_TENSILE_LIBPATH=$ROCBLAS_LIB
OLLAMA_HOST=$HOST
HIP_VISIBLE_DEVICES=$HIP_DEVICES
HSA_OVERRIDE_GFX_VERSION=$HSA_GFX
LOG_FILE=$LOG_FILE
PID_FILE=$PID_FILE
EOF
}

start_server() {
  if systemctl --user is-active --quiet ollama; then
    echo "user service ollama is active; stop it first:" >&2
    echo "  systemctl --user stop ollama" >&2
    exit 1
  fi

  if running_pid >/dev/null 2>&1; then
    local pid
    pid="$(running_pid)"
    echo "manual ollama serve already running (pid=$pid)"
    status_server
    return 0
  fi

  require_file "$OLLAMA_BIN" "ollama binary"
  require_file "$MODELS_DIR" "models directory"
  require_file "$LIB_DIR/libggml-hip.so" "backend library"

  mkdir -p "$(dirname "$LOG_FILE")"

  OLLAMA_MODELS="$MODELS_DIR" \
  OLLAMA_HOST="$HOST" \
  OLLAMA_LIBRARY_PATH="$LIB_DIR" \
  LD_LIBRARY_PATH="$LIB_DIR" \
  ROCBLAS_TENSILE_LIBPATH="$ROCBLAS_LIB" \
  HIP_VISIBLE_DEVICES="$HIP_DEVICES" \
  HSA_OVERRIDE_GFX_VERSION="$HSA_GFX" \
  nohup "$OLLAMA_BIN" serve >>"$LOG_FILE" 2>&1 &

  local pid=$!
  echo "$pid" > "$PID_FILE"
  sleep 1

  if ! ps -p "$pid" >/dev/null 2>&1; then
    echo "manual ollama serve failed to start; see log: $LOG_FILE" >&2
    exit 1
  fi

  echo "started manual ollama serve (pid=$pid)"
  status_server
}

stop_server() {
  local pid
  pid="$(running_pid || true)"
  if [[ -z "$pid" ]]; then
    echo "manual ollama serve is not running"
    rm -f "$PID_FILE"
    return 0
  fi

  kill "$pid" 2>/dev/null || true
  sleep 1
  if ps -p "$pid" >/dev/null 2>&1; then
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$PID_FILE"
  echo "stopped manual ollama serve (pid=$pid)"
}

status_server() {
  local pid
  pid="$(running_pid || true)"
  if [[ -z "$pid" ]]; then
    echo "status: stopped"
    return 0
  fi

  echo "status: running (pid=$pid)"
  echo "serve listener (OLLAMA_HOST):"
  ss -ltnp | rg "${HOST##*:}|pid=$pid" || true

  echo "runner processes/listeners:"
  local child_pids
  child_pids="$(pgrep -P "$pid" || true)"
  if [[ -z "$child_pids" ]]; then
    echo "  (no active runner child processes)"
  else
    ps -fp $child_pids || true
    ss -ltnp | rg "$(echo "$child_pids" | tr '\n' '|' | sed 's/|$//')" || true
  fi

  echo "runtime env (from /proc):"
  tr '\0' '\n' < "/proc/$pid/environ" | rg '^(OLLAMA_MODELS|OLLAMA_HOST|OLLAMA_LIBRARY_PATH|ROCBLAS_TENSILE_LIBPATH|HIP_VISIBLE_DEVICES|HSA_OVERRIDE_GFX_VERSION|LD_LIBRARY_PATH)=' || true
}

run_model() {
  local model="${1:-}"
  shift || true

  if [[ -z "$model" ]]; then
    echo "model is required: ./ollama-manual.sh run <model> [prompt...]" >&2
    exit 1
  fi

  if ! running_pid >/dev/null 2>&1; then
    start_server
  fi

  if [[ $# -eq 0 ]]; then
    OLLAMA_HOST="$HOST" ollama run "$model"
  else
    OLLAMA_HOST="$HOST" ollama run "$model" "$*"
  fi
}

cmd="${1:-}"
case "$cmd" in
  start)
    shift
    print_env_summary
    start_server
    ;;
  stop)
    shift
    stop_server
    ;;
  restart)
    shift
    stop_server
    print_env_summary
    start_server
    ;;
  status)
    shift
    print_env_summary
    status_server
    ;;
  run)
    shift
    run_model "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
