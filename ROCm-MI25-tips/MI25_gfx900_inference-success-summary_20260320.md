# MI25/gfx900 ROCm Inference Success Summary (2026-03-20)

## TL;DR

MI25 (gfx900) on ROCm 7.2 can run Ollama inference on GPU, including `deepseek-r1:14b`.
The major blocker was not MI25 capability itself, but backend library placement consistency.

## Environment

- GPU: Radeon Instinct MI25 (gfx900)
- Runtime: ROCm 7.2
- Serving: Ollama user service (source build)
- Key env path: `OLLAMA_LIBRARY_PATH=/home/limonene/ROCm-project/ollama-src/build/lib/ollama`

## What failed before

- CPU fallback appeared repeatedly after restart.
- Investigation showed backend directory reference existed but backend files could be missing/inconsistent.
- In that state, service often selected CPU path (`library=cpu`, `GPULayers:[]`).

## Fix applied

- Rebuild Ollama backend libraries with `build-ollama-gfx900.sh`.
- Confirm `libggml-hip.so` and related files exist at runtime path.
- Add preflight checks to scripts/service setup to fail fast when backend files are missing.

## Validation evidence

### tinyllama A/B after recovery

- 8-case matrix (restart/warm-up/keep_alive)
- Result: 16 phases total, `GPU=15`, `UNSURE=1`
- UNSURE rerun later resolved to GPU

### deepseek-r1:14b run

- `done=true`, `done_reason=length`
- Journal: `library=ROCm`, `compute=gfx900`, `GPULayers:49`, `offloaded 49/49 layers to GPU`
- rocm-smi: GPU use up to 99%, power up to 217W, VRAM around 58%

## Main conclusion

MI25/gfx900 inference path is viable in this setup.
Primary reliability risk is backend deployment integrity (missing/misaligned runtime libraries), not intrinsic GPU incompatibility.

## Evidence files

- `vega_path_check_logs/deepseek14b_generate_20260320_212146.json`
- `vega_path_check_logs/deepseek14b_journal_20260320_212146.log`
- `vega_path_check_logs/deepseek14b_rocm_smi_20260320_212146.log`
- `vega_path_check_logs/tinyllama_path_index_20260320_195741.tsv`
- `vega_path_check_logs/tinyllama_path_index_20260320_200424.tsv`
- `assets/screen_shot-gfx900-deepseek-r1.png`
