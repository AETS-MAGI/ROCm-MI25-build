#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${HOME:-/home/$USER}/ROCm-project"
SELF_REPO_URL="https://github.com/AETS-MAGI/ROCm-MI25-build.git"
SELF_DIR_NAME="ROCm-MI25-build"
OLLAMA_REPO_URL="https://github.com/AETS-MAGI/ollama-gfx900_aets-lab.git"
ROCBLAS_REPO_URL="https://github.com/AETS-MAGI/rocBLAS-gfx900_aets-lab.git"
TENSILE_REPO_URL="https://github.com/AETS-MAGI/Tensile-gfx900_aets-lab.git"
DRY_RUN=0
SKIP_SELF=0

usage() {
  cat <<'EOF'
Usage: ./bootstrap-workspace.sh [options]

Options:
  --root-dir <path>         Workspace root (default: /home/$USER/ROCm-project)
  --self-repo-url <url>     ROCm-MI25-build repository URL
  --ollama-repo-url <url>   Ollama fork repository URL
  --rocblas-repo-url <url>  rocBLAS fork repository URL
  --tensile-repo-url <url>  Tensile fork repository URL
  --skip-self               Do not clone/update ROCm-MI25-build itself
  --dry-run                 Print planned actions without changing files
  -h, --help                Show help

Resulting layout:
  <root>/ROCm-MI25-build
  <root>/ollama-src
  <root>/ROCm-repos_AETS/rocBLAS
  <root>/ROCm-repos_AETS/Tensile
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-dir)
      ROOT_DIR="$2"
      shift 2
      ;;
    --self-repo-url)
      SELF_REPO_URL="$2"
      shift 2
      ;;
    --ollama-repo-url)
      OLLAMA_REPO_URL="$2"
      shift 2
      ;;
    --rocblas-repo-url)
      ROCBLAS_REPO_URL="$2"
      shift 2
      ;;
    --tensile-repo-url)
      TENSILE_REPO_URL="$2"
      shift 2
      ;;
    --skip-self)
      SKIP_SELF=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
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

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 1
  fi
}

run_cmd() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

clone_or_update() {
  local url="$1"
  local dir="$2"

  if [[ -d "$dir/.git" ]]; then
    echo "[update] $dir"
    run_cmd "git -C \"$dir\" fetch --all --tags --prune"
  elif [[ -e "$dir" ]]; then
    echo "error: target exists but is not a git repo: $dir" >&2
    exit 1
  else
    echo "[clone] $url -> $dir"
    run_cmd "git clone \"$url\" \"$dir\""
  fi
}

require_cmd git

ROOT_DIR="$(realpath -m "$ROOT_DIR")"
AETS_DIR="$ROOT_DIR/ROCm-repos_AETS"
SELF_DIR="$ROOT_DIR/$SELF_DIR_NAME"
OLLAMA_DIR="$ROOT_DIR/ollama-src"
ROCBLAS_DIR="$AETS_DIR/rocBLAS"
TENSILE_DIR="$AETS_DIR/Tensile"

echo "Workspace root: $ROOT_DIR"
run_cmd "mkdir -p \"$ROOT_DIR\" \"$AETS_DIR\""

if [[ $SKIP_SELF -eq 0 ]]; then
  clone_or_update "$SELF_REPO_URL" "$SELF_DIR"
fi

clone_or_update "$OLLAMA_REPO_URL" "$OLLAMA_DIR"
clone_or_update "$ROCBLAS_REPO_URL" "$ROCBLAS_DIR"
clone_or_update "$TENSILE_REPO_URL" "$TENSILE_DIR"

echo
echo "Workspace layout ready:"
echo "  $SELF_DIR"
echo "  $OLLAMA_DIR"
echo "  $ROCBLAS_DIR"
echo "  $TENSILE_DIR"

echo
echo "Next steps:"
echo "  cd $SELF_DIR"
echo "  ./rocm-install.sh"
echo "  ./build-rocblas-gfx900.sh"
echo "  ./build-ollama-gfx900.sh --ref main"
echo "  ./ollama-setup.sh --service user"
