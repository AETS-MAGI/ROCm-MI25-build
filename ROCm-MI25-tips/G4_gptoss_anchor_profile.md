# G4 gpt-oss Anchor Profile (MI25/gfx900)

Last updated: 2026-03-24
Owner scope: `ROCm-MI25-build`

This file is the canonical profile for dispatch-visible G4 probing.
Use this as the source of truth before running shape-level comparisons.

## 1. Canonical anchor (baseline)

Status: `[main-node confirmed]`

Fixed conditions:

- `MODEL=gpt-oss:latest`
- `ROCBLAS_LAYER=9`
- `NUM_CTX=8192`
- `NUM_BATCH=512`
- `NUM_PREDICT in {64,128,256}`
- `KEEP_ALIVE=5m`
- `TEMPERATURE=0.1`

Primary shape target set (`batch=512`):

- `512x512x2880`
- `4096x512x64`
- `64x512x4096`
- `2880x512x4096`
- `4096x512x2880`

Expected gate behavior:

- `direct_rocblas_or_tensile_dispatch=1`
- `fallback_confirmed=1`
- `dispatch_confirmed=1`

## 2. Side profile (shape-shift channel)

Status: `[main-node confirmed]`

Use this to observe shape migration while keeping direct dispatch visible.

Fixed conditions:

- same as baseline, except `NUM_BATCH=1024`

Side target set (`batch=1024`):

- `512x1024x2880`
- `4096x1024x64`
- `64x1024x4096`
- `2880x1024x4096`
- `4096x1024x2880`

## 3. Repro commands

Baseline (`batch=512`):

```bash
cd /home/$USER/ROCm-project/ROCm-MI25-build
MODEL='gpt-oss:latest' \
NUM_PREDICT_LIST='64,128,256' \
NUM_CTX_LIST='8192' \
NUM_BATCH_LIST='512' \
KEEP_ALIVE_LIST='5m' \
RUNS_PER_CASE=1 \
./g4-gptoss-anchor-shape-sweep.sh
```

Side (`batch=1024`, 1024-targets):

```bash
cd /home/$USER/ROCm-project/ROCm-MI25-build
MODEL='gpt-oss:latest' \
NUM_PREDICT_LIST='64,128,256' \
NUM_CTX_LIST='8192' \
NUM_BATCH_LIST='1024' \
TARGET_SHAPES='512x1024x2880,4096x1024x64,64x1024x4096,2880x1024x4096,4096x1024x2880' \
KEEP_ALIVE_LIST='5m' \
RUNS_PER_CASE=1 \
./g4-gptoss-anchor-shape-sweep.sh
```

## 4. Latest verified snapshots

`[main-node confirmed]`

Baseline summary:

- `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260324_034636.txt`
- highlights:
  - `ok_cases=3`, `direct_hits=3`
  - `shape_512x512x2880=576`
  - `shape_2880x512x4096=288`
  - `shape_4096x512x2880=288`

Side summary (1024-targets):

- `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260324_035250.txt`
- highlights:
  - `ok_cases=3`, `direct_hits=3`
  - `shape_512x1024x2880=864`
  - `shape_2880x1024x4096=432`
  - `shape_4096x1024x2880=432`

## 5. Operational interpretation

- Baseline and side both keep direct-dispatch visibility.
- `NUM_BATCH` changes shape family (`*x512x*` -> `*x1024x*`) while preserving gate success.
- Therefore:
  - baseline = default tuning reference
  - side = shape-shift sensitivity reference

Status label: `[inference / unvalidated]` for future cases until each run re-confirms gate metrics.
