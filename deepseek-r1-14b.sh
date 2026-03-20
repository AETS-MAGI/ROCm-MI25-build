#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Wrapper around generic model checker with a deepseek default.
MODEL="${MODEL:-deepseek-r1:14b}"
NUM_PREDICT="${NUM_PREDICT:-220}"
TEMPERATURE="${TEMPERATURE:-0.1}"
KEEP_ALIVE="${KEEP_ALIVE:-0s}"
PROMPT="${PROMPT:-Write a plain-text 200-word note summarizing MI25 ROCm validation checkpoints.}"

exec "$SCRIPT_DIR/model-gpu-path-check.sh" "$MODEL"