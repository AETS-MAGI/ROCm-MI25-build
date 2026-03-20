#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/home/limonene/ROCm-project"
ROCBLAS_SRC_DIR="$ROOT_DIR/ROCm-repos_AETS/rocBLAS"
TENSILE_SRC_DIR="$ROOT_DIR/ROCm-repos_AETS/Tensile"
BUILD_DIR="$ROCBLAS_SRC_DIR/build-mi25-gfx900"
JOBS="$(nproc)"
RUN_DEPS=0

usage() {
  cat <<'EOF'
Usage: ./build-rocblas-gfx900.sh [options]

Options:
  --src-dir <path>     rocBLAS source dir (default: /home/$USER/ROCm-project/ROCm-repos_AETS/rocBLAS)
  --tensile-dir <path> Tensile source dir (default: /home/$USER/ROCm-project/ROCm-repos_AETS/Tensile)
  --build-dir <path>   Build dir (default: <src>/build-mi25-gfx900)
  --jobs <n>           Parallel jobs (default: nproc)
  --deps               Run dependency install step in install.sh (-d)
  -h, --help           Show help

Output of interest:
  <build-dir>/release/rocblas-install/lib/rocblas/library

Notes:
  - This build targets gfx900 and keeps artifacts separate from system ROCm.
  - Use the output path with ollama-setup.sh --rocblas-libpath to test MI25 runtime.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-dir)
      ROCBLAS_SRC_DIR="$2"
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --tensile-dir)
      TENSILE_SRC_DIR="$2"
      shift 2
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --deps)
      RUN_DEPS=1
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

ROCBLAS_SRC_DIR="$(realpath -m "$ROCBLAS_SRC_DIR")"
TENSILE_SRC_DIR="$(realpath -m "$TENSILE_SRC_DIR")"
BUILD_DIR="$(realpath -m "$BUILD_DIR")"

if [[ ! -d "$ROCBLAS_SRC_DIR/.git" ]]; then
  echo "error: rocBLAS git repo not found: $ROCBLAS_SRC_DIR" >&2
  exit 1
fi

if [[ ! -d "$TENSILE_SRC_DIR/.git" ]]; then
  echo "error: Tensile git repo not found: $TENSILE_SRC_DIR" >&2
  exit 1
fi

if [[ "$TENSILE_SRC_DIR" == *"/00_legacy-repos/"* ]]; then
  echo "error: refusing legacy Tensile path: $TENSILE_SRC_DIR" >&2
  echo "hint: use ROCm-repos_AETS/Tensile (active fork) instead." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not found" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake not found" >&2
  exit 1
fi

if [[ ! -x /opt/rocm/llvm/bin/clang++ ]]; then
  echo "error: ROCm clang++ not found at /opt/rocm/llvm/bin/clang++" >&2
  exit 1
fi

cd "$ROCBLAS_SRC_DIR"
mkdir -p "$BUILD_DIR"

ARGS=(
  --build_dir "$BUILD_DIR"
  -a gfx900
  --jobs "$JOBS"
  --no_hipblaslt
  --skipldconf
  --test_local_path "$TENSILE_SRC_DIR"
)

if [[ $RUN_DEPS -eq 1 ]]; then
  ARGS+=( -d )
fi

echo "[rocBLAS] src      : $ROCBLAS_SRC_DIR"
echo "[rocBLAS] build    : $BUILD_DIR"
echo "[rocBLAS] tensile  : $TENSILE_SRC_DIR"
echo "[rocBLAS] arch     : gfx900"
echo "[rocBLAS] jobs     : $JOBS"
echo "[rocBLAS] deps     : $RUN_DEPS"

bash ./install.sh "${ARGS[@]}"

OUT_LIBPATH="$BUILD_DIR/release/rocblas-install/lib/rocblas/library"

cat <<EOF

Build finished.

Expected rocBLAS Tensile path:
  $OUT_LIBPATH

If the directory exists, apply it to Ollama service:
  ./ollama-setup.sh --service user --no-install --rocblas-libpath "$OUT_LIBPATH"
  systemctl --user restart ollama
EOF
