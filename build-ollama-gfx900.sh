#!/usr/bin/env bash
set -euo pipefail

# Build Ollama from source with gfx900 HIP target support.
# This script does not install system service automatically.

ROOT_DIR="/home/limonene/ROCm-project"
SRC_DIR="$ROOT_DIR/ollama-src"
BUILD_DIR="$SRC_DIR/build-gfx900"
INSTALL_DIR="$ROOT_DIR/ollama-gfx900-install"
BRANCH_OR_TAG=""
REPO_URL="${OLLAMA_REPO_URL:-https://github.com/ollama/ollama.git}"
RUN_BUILD=1
RUN_INSTALL=0

usage() {
  cat <<'EOF'
Usage: ./build-ollama-gfx900.sh [options]

Options:
  --src-dir <path>        Source directory (default: /home/$USER/ROCm-project/ollama-src)
  --build-dir <path>      CMake build directory (default: <src>/build-gfx900)
  --install-dir <path>    Install prefix for cmake install (default: /home/$USER/ROCm-project/ollama-gfx900-install)
  --repo-url <url>        Git repository URL for clone (default: OLLAMA_REPO_URL or upstream ollama/ollama)
  --ref <git-ref>         Checkout branch/tag/commit after clone
  --no-build              Prepare source/configure only
  --install               Run cmake --install after build
  -h, --help              Show help

Examples:
  ./build-ollama-gfx900.sh
  ./build-ollama-gfx900.sh --repo-url https://github.com/<org-or-user>/<repo>.git --ref main
  ./build-ollama-gfx900.sh --ref v0.18.2
  ./build-ollama-gfx900.sh --no-build
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-dir)
      SRC_DIR="$2"
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --ref)
      BRANCH_OR_TAG="$2"
      shift 2
      ;;
    --no-build)
      RUN_BUILD=0
      shift
      ;;
    --install)
      RUN_INSTALL=1
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

require_cmd git
require_cmd cmake
require_cmd ninja
require_cmd go
require_cmd hipcc

if [[ ! -x /opt/rocm/llvm/bin/clang ]]; then
  echo "ROCm clang not found at /opt/rocm/llvm/bin/clang" >&2
  exit 1
fi
if [[ ! -x /opt/rocm/llvm/bin/clang++ ]]; then
  echo "ROCm clang++ not found at /opt/rocm/llvm/bin/clang++" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR"

if [[ ! -d "$SRC_DIR/.git" ]]; then
  echo "Cloning Ollama source into $SRC_DIR"
  echo "Repository: $REPO_URL"
  git clone "$REPO_URL" "$SRC_DIR"
else
  echo "Using existing source tree: $SRC_DIR"
fi

cd "$SRC_DIR"
git fetch --all --tags --prune
if [[ -n "$BRANCH_OR_TAG" ]]; then
  git checkout "$BRANCH_OR_TAG"
fi

# Ensure ggml native artifacts are rebuilt for this toolchain.
go clean -cache

mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

export PATH="/opt/rocm/bin:/opt/rocm/llvm/bin:$PATH"
export CC="/opt/rocm/llvm/bin/clang"
export CXX="/opt/rocm/llvm/bin/clang++"
export CMAKE_GENERATOR="Ninja"

# Force HIP backend for gfx900 even though upstream default filter excludes it.
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_HIP_COMPILER=/opt/rocm/llvm/bin/clang++ \
  -DGPU_TARGETS=gfx900 \
  -DAMDGPU_TARGETS=gfx900

if [[ $RUN_BUILD -eq 1 ]]; then
  cmake --build "$BUILD_DIR" --parallel "$(nproc)"
fi

if [[ $RUN_INSTALL -eq 1 ]]; then
  cmake --install "$BUILD_DIR"
fi

cat <<EOF

Build flow completed.

Source      : $SRC_DIR
Build dir   : $BUILD_DIR
Install dir : $INSTALL_DIR
Repo URL    : $REPO_URL

Run built server (without install):
  cd $SRC_DIR
  GIN_MODE=release ./ollama serve

Tip:
  To prefer this binary over /usr/local/bin/ollama, prepend PATH with:
  export PATH="$SRC_DIR:$PATH"
EOF
