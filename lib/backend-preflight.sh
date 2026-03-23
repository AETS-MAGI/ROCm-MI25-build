#!/usr/bin/env bash

# Shared backend preflight helpers for MI25/gfx900 scripts.
# Usage:
#   source "$SCRIPT_DIR/lib/backend-preflight.sh"
#   backend_preflight_check "$BACKEND_DIR" "$SUMMARY_FILE"

backend_preflight_log() {
  local message="$1"
  local log_file="${2:-}"

  if [[ -n "$log_file" ]]; then
    echo "$message" | tee -a "$log_file"
  else
    echo "$message"
  fi
}

backend_preflight_check() {
  local backend_dir="$1"
  local log_file="${2:-}"
  local missing=0
  local resolved_dir=""
  local required=(
    "libggml-hip.so"
    "libggml-base.so"
    "libggml-cpu-haswell.so"
  )

  if [[ -z "$backend_dir" ]]; then
    backend_preflight_log "ERROR: backend directory is empty" "$log_file"
    return 1
  fi

  if [[ ! -d "$backend_dir" ]]; then
    backend_preflight_log "ERROR: backend directory is missing: $backend_dir" "$log_file"
    return 1
  fi

  if [[ -L "$backend_dir" ]]; then
    resolved_dir="$(readlink -f "$backend_dir" || true)"
    if [[ -z "$resolved_dir" || ! -d "$resolved_dir" ]]; then
      backend_preflight_log "ERROR: backend directory symlink is broken: $backend_dir" "$log_file"
      return 1
    fi
  fi

  local file_path=""
  local resolved_file=""
  local name=""
  for name in "${required[@]}"; do
    file_path="$backend_dir/$name"

    if [[ ! -e "$file_path" ]]; then
      backend_preflight_log "ERROR: backend file is missing: $file_path" "$log_file"
      missing=1
      continue
    fi

    if [[ -L "$file_path" ]]; then
      resolved_file="$(readlink -f "$file_path" || true)"
      if [[ -z "$resolved_file" || ! -f "$resolved_file" ]]; then
        backend_preflight_log "ERROR: backend file symlink is broken: $file_path" "$log_file"
        missing=1
        continue
      fi
    fi

    if [[ ! -f "$file_path" ]]; then
      backend_preflight_log "ERROR: backend entry is not a regular file: $file_path" "$log_file"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    return 1
  fi

  backend_preflight_log "backend_dir=$backend_dir" "$log_file"
  if [[ -n "$resolved_dir" ]]; then
    backend_preflight_log "backend_dir_real=$resolved_dir" "$log_file"
  fi
  backend_preflight_log "backend_check=ok" "$log_file"
}
