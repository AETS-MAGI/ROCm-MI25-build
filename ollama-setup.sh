#!/usr/bin/env bash
set -euo pipefail

MODELS_DIR="/home/limonene/ROCm-project/ollama-models"
SERVICE_MODE="auto"   # auto | user | system
INSTALL_IF_MISSING=1
NO_START=0
PROFILE="mi25"        # mi25 | custom
GPU_DEVICES=""
NUM_PARALLEL="1"
MAX_LOADED_MODELS="1"
KEEP_ALIVE="10m"
OLLAMA_HOST="127.0.0.1:11434"
EXEC_PATH=""
LIBRARY_PATH=""
EXTRA_LD_LIBRARY_PATH=""
ROCBLAS_LIBPATH=""

usage() {
  cat <<'EOF'
Usage: ./ollama-setup.sh [options]

Options:
  --models-dir <path>   Ollama model directory (default: /home/$USER/ROCm-project/ollama-models)
  --service <mode>      Service mode: auto | user | system (default: auto)
  --profile <name>      Runtime profile: mi25 | custom (default: mi25)
  --gpu-devices <list>  HIP_VISIBLE_DEVICES value (e.g. 0 or 0,1)
  --num-parallel <n>    OLLAMA_NUM_PARALLEL value (default: 1)
  --max-loaded <n>      OLLAMA_MAX_LOADED_MODELS value (default: 1)
  --keep-alive <value>  OLLAMA_KEEP_ALIVE value (default: 10m)
  --host <addr>         OLLAMA_HOST value (default: 127.0.0.1:11434)
  --exec-path <path>    Absolute path to ollama binary for user service ExecStart
  --library-path <path> OLLAMA_LIBRARY_PATH value (optional)
  --ld-library-path <p> LD_LIBRARY_PATH value (optional)
  --rocblas-libpath <p> ROCBLAS_TENSILE_LIBPATH value (optional)
  --no-install          Do not install Ollama if missing
  --no-start            Do not start/restart service
  -h, --help            Show this help

Notes:
  - This script configures OLLAMA_MODELS to a custom directory.
  - For Vega/gfx900 environments, HSA_OVERRIDE_GFX_VERSION=9.0.0 is set.
  - mi25 profile is conservative: single parallel request and one loaded model.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models-dir)
      MODELS_DIR="$2"
      shift 2
      ;;
    --service)
      SERVICE_MODE="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --gpu-devices)
      GPU_DEVICES="$2"
      shift 2
      ;;
    --num-parallel)
      NUM_PARALLEL="$2"
      shift 2
      ;;
    --max-loaded)
      MAX_LOADED_MODELS="$2"
      shift 2
      ;;
    --keep-alive)
      KEEP_ALIVE="$2"
      shift 2
      ;;
    --host)
      OLLAMA_HOST="$2"
      shift 2
      ;;
    --exec-path)
      EXEC_PATH="$2"
      shift 2
      ;;
    --library-path)
      LIBRARY_PATH="$2"
      shift 2
      ;;
    --ld-library-path)
      EXTRA_LD_LIBRARY_PATH="$2"
      shift 2
      ;;
    --rocblas-libpath)
      ROCBLAS_LIBPATH="$2"
      shift 2
      ;;
    --no-install)
      INSTALL_IF_MISSING=0
      shift
      ;;
    --no-start)
      NO_START=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$SERVICE_MODE" != "auto" && "$SERVICE_MODE" != "user" && "$SERVICE_MODE" != "system" ]]; then
  echo "Invalid --service value: $SERVICE_MODE" >&2
  exit 1
fi

if [[ "$PROFILE" != "mi25" && "$PROFILE" != "custom" ]]; then
  echo "Invalid --profile value: $PROFILE" >&2
  exit 1
fi

if [[ ! "$NUM_PARALLEL" =~ ^[0-9]+$ ]] || [[ ! "$MAX_LOADED_MODELS" =~ ^[0-9]+$ ]]; then
  echo "--num-parallel and --max-loaded must be integer values." >&2
  exit 1
fi

if [[ "$PROFILE" == "mi25" ]]; then
  # MI25 is stable with conservative concurrency on many ROCm setups.
  NUM_PARALLEL="1"
  MAX_LOADED_MODELS="1"
  KEEP_ALIVE="10m"
  if [[ -z "$GPU_DEVICES" ]]; then
    GPU_DEVICES="0"
  fi
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 1
  fi
}

maybe_install_ollama() {
  if command -v ollama >/dev/null 2>&1; then
    return 0
  fi

  if [[ $INSTALL_IF_MISSING -eq 0 ]]; then
    echo "Ollama is not installed and --no-install was specified." >&2
    exit 1
  fi

  require_cmd curl
  require_cmd sudo

  echo "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh

  if ! command -v ollama >/dev/null 2>&1; then
    echo "Ollama installation finished but binary was not found in PATH." >&2
    echo "Open a new shell and run this script again." >&2
    exit 1
  fi
}

resolve_exec_path() {
  if [[ -n "$EXEC_PATH" ]]; then
    if [[ ! -x "$EXEC_PATH" ]]; then
      echo "error: --exec-path is not executable: $EXEC_PATH" >&2
      exit 1
    fi
    echo "$EXEC_PATH"
    return 0
  fi

  command -v ollama
}

resolve_library_path_for_user() {
  local resolved_exec="$1"

  if [[ -n "$LIBRARY_PATH" ]]; then
    if [[ ! -d "$LIBRARY_PATH" ]]; then
      echo "error: --library-path is not a directory: $LIBRARY_PATH" >&2
      exit 1
    fi
    echo "$LIBRARY_PATH"
    return 0
  fi

  # Source tree build convention: <repo>/ollama as binary, <repo>/build/lib/ollama as runtime libs.
  local candidate
  candidate="$(dirname "$resolved_exec")/build/lib/ollama"
  if [[ -d "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  echo ""
}

resolve_service_mode() {
  if [[ "$SERVICE_MODE" != "auto" ]]; then
    echo "$SERVICE_MODE"
    return 0
  fi

  if systemctl cat ollama >/dev/null 2>&1; then
    echo "system"
    return 0
  fi

  # Prefer user service for user-owned model directories.
  echo "user"
}

configure_system_service() {
  require_cmd sudo
  local dropin_dir="/etc/systemd/system/ollama.service.d"
  local dropin_file="$dropin_dir/override-models.conf"

  echo "Configuring system ollama service..."
  sudo mkdir -p "$dropin_dir"
  sudo mkdir -p "$MODELS_DIR"

  {
    cat <<'EOF'
[Service]
EOF
    echo "Environment=\"OLLAMA_MODELS=$MODELS_DIR\""
    echo "Environment=\"HSA_OVERRIDE_GFX_VERSION=9.0.0\""
    echo "Environment=\"OLLAMA_HOST=$OLLAMA_HOST\""
    echo "Environment=\"OLLAMA_NUM_PARALLEL=$NUM_PARALLEL\""
    echo "Environment=\"OLLAMA_MAX_LOADED_MODELS=$MAX_LOADED_MODELS\""
    echo "Environment=\"OLLAMA_KEEP_ALIVE=$KEEP_ALIVE\""
    if [[ -n "$LIBRARY_PATH" ]]; then
      echo "Environment=\"OLLAMA_LIBRARY_PATH=$LIBRARY_PATH\""
    fi
    if [[ -n "$EXTRA_LD_LIBRARY_PATH" ]]; then
      echo "Environment=\"LD_LIBRARY_PATH=$EXTRA_LD_LIBRARY_PATH\""
    fi
    if [[ -n "$ROCBLAS_LIBPATH" ]]; then
      echo "Environment=\"ROCBLAS_TENSILE_LIBPATH=$ROCBLAS_LIBPATH\""
    fi
    if [[ -n "$GPU_DEVICES" ]]; then
      echo "Environment=\"HIP_VISIBLE_DEVICES=$GPU_DEVICES\""
    fi
  } | sudo tee "$dropin_file" >/dev/null

  if id ollama >/dev/null 2>&1; then
    sudo chown -R ollama:ollama "$MODELS_DIR"

    if ! sudo -u ollama test -w "$MODELS_DIR"; then
      echo ""
      echo "ERROR: system service user 'ollama' cannot write to $MODELS_DIR" >&2
      echo "This often happens when a parent directory is not traversable by 'ollama'." >&2
      echo ""
      echo "Fix options:" >&2
      echo "  1) Recommended: use user service mode" >&2
      echo "     ./ollama-setup.sh --service user" >&2
      echo "  2) Keep system mode: grant traverse permission to path parents (ACL)" >&2
      echo "     sudo setfacl -m u:ollama:x /home/$USER" >&2
      echo ""
      echo "Aborting to avoid a broken model storage configuration." >&2
      exit 1
    fi
  fi

  sudo systemctl daemon-reload
  if [[ $NO_START -eq 0 ]]; then
    sudo systemctl enable --now ollama
  fi
}

configure_user_service() {
  local user_unit_dir="$HOME/.config/systemd/user"
  local unit_file="$user_unit_dir/ollama.service"
  local resolved_exec
  local resolved_library_path
  local resolved_ld_library_path
  resolved_exec="$(resolve_exec_path)"
  resolved_library_path="$(resolve_library_path_for_user "$resolved_exec")"

  if [[ -n "$EXTRA_LD_LIBRARY_PATH" ]]; then
    resolved_ld_library_path="$EXTRA_LD_LIBRARY_PATH"
  elif [[ -n "$resolved_library_path" ]]; then
    resolved_ld_library_path="$resolved_library_path"
  else
    resolved_ld_library_path=""
  fi

  echo "Configuring user ollama service..."
  mkdir -p "$user_unit_dir"
  mkdir -p "$MODELS_DIR"

  if [[ ! -w "$MODELS_DIR" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo chown -R "$USER:$USER" "$MODELS_DIR" || true
    fi
  fi

  if [[ ! -w "$MODELS_DIR" ]]; then
    echo "error: models dir is not writable by user '$USER': $MODELS_DIR" >&2
    echo "hint: run one of the following and retry:" >&2
    echo "  sudo chown -R $USER:$USER $MODELS_DIR" >&2
    echo "  chmod -R u+rwX $MODELS_DIR" >&2
    exit 1
  fi

  {
    cat <<EOF
[Unit]
Description=Ollama Service (user)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$resolved_exec serve
Restart=always
RestartSec=3
Environment="OLLAMA_MODELS=$MODELS_DIR"
Environment="HSA_OVERRIDE_GFX_VERSION=9.0.0"
Environment="OLLAMA_HOST=$OLLAMA_HOST"
Environment="OLLAMA_NUM_PARALLEL=$NUM_PARALLEL"
Environment="OLLAMA_MAX_LOADED_MODELS=$MAX_LOADED_MODELS"
Environment="OLLAMA_KEEP_ALIVE=$KEEP_ALIVE"
EOF
    if [[ -n "$resolved_library_path" ]]; then
      echo "Environment=\"OLLAMA_LIBRARY_PATH=$resolved_library_path\""
    fi
    if [[ -n "$resolved_ld_library_path" ]]; then
      echo "Environment=\"LD_LIBRARY_PATH=$resolved_ld_library_path\""
    fi
    if [[ -n "$ROCBLAS_LIBPATH" ]]; then
      echo "Environment=\"ROCBLAS_TENSILE_LIBPATH=$ROCBLAS_LIBPATH\""
    fi
    if [[ -n "$GPU_DEVICES" ]]; then
      echo "Environment=\"HIP_VISIBLE_DEVICES=$GPU_DEVICES\""
    fi
    cat <<'EOF'

[Install]
WantedBy=default.target
EOF
  } > "$unit_file"

  systemctl --user daemon-reload
  if [[ $NO_START -eq 0 ]]; then
    systemctl --user enable --now ollama
  fi
}

show_summary() {
  echo
  echo "Setup complete."
  echo "  service mode : $1"
  echo "  profile      : $PROFILE"
  echo "  models dir   : $MODELS_DIR"
  echo "  host         : $OLLAMA_HOST"
  echo "  parallel     : $NUM_PARALLEL"
  echo "  max loaded   : $MAX_LOADED_MODELS"
  echo "  keep alive   : $KEEP_ALIVE"
  echo "  gpu devices  : ${GPU_DEVICES:-<unset>}"
  echo "  lib path     : ${LIBRARY_PATH:-<auto>}"
  echo "  ld lib path  : ${EXTRA_LD_LIBRARY_PATH:-<auto>}"
  echo "  rocblas path : ${ROCBLAS_LIBPATH:-<unset>}"
  echo
  echo "Verify with:"
  if [[ "$1" == "system" ]]; then
    echo "  sudo systemctl status ollama --no-pager"
  else
    echo "  systemctl --user status ollama --no-pager"
  fi
  echo "  OLLAMA_MODELS=$MODELS_DIR ollama list"
}

require_cmd systemctl
maybe_install_ollama

MODE="$(resolve_service_mode)"
if [[ "$MODE" == "system" ]]; then
  configure_system_service
else
  configure_user_service
fi

show_summary "$MODE"
