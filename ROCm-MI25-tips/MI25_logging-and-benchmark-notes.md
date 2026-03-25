# MI25/gfx900 ログ運用・ベンチメモ

## 1. ログ命名規則

- 1ユニットは以下3点セットで扱う。
  - `*_generate_YYYYmmdd_HHMMSS.json`
  - `*_journal_YYYYmmdd_HHMMSS.log`
  - `*_rocm_smi_YYYYmmdd_HHMMSS.log`
- 生成ログのみでは判定しない。必ず journal と rocm-smi を併記する。

## 2. TSV 列説明（tinyllama A/B）

- `case`: 実験条件名（例: `r1_w0_k1`）
- `phase`: `first` / `second`
- `verdict`: `GPU` / `CPU` / `MIXED` / `UNSURE`
- `max_gpu_use`: その phase の GPU 使用率最大値
- `inference_library`: journal から抽出した `library=` 値
- `inference_compute`: journal から抽出した `compute=` 値
- `gpulayers`: journal から抽出した `GPULayers` 値
- `json`, `journal`, `rocm_smi`: 各証跡ファイルパス

## 3. 速度比較の最小手順

同一条件で比較する。

- prompt: 固定
- `num_predict`: 固定
- `temperature`: 固定
- keep_alive: 固定
- 直前に `ollama stop <model>` で保持状態を揃える

例:

```bash
MODEL=deepseek-r1:14b NUM_PREDICT=140 TEMPERATURE=0.1 KEEP_ALIVE=0s \
  ./model-gpu-path-check.sh
```

## 4. MI25 と他GPUの簡易比較条件

- 比較対象ごとに `HIP_VISIBLE_DEVICES` を固定。
- 同一モデル、同一 prompt、同一 `num_predict` を使用。
- 指標は少なくとも以下を揃える。
  - `total_duration`
  - `eval_count`
  - `tokens/sec`（`eval_count / (total_duration[s])`）
  - `max_gpu_use`
  - `max power`
  - `max VRAM%`

## 5. 参考値（現状）

- deepseek-r1:14b (MI25)
  - `eval_count=140`
  - `total_duration=14197760256 ns`（約 14.20 s）
  - 推定 `tokens/sec` 約 9.9
  - VRAM 目安: 約 58%
- tinyllama（A/B 実行の代表例）
  - `eval_count=96`
  - `total_duration=1562813760 ns`（約 1.56 s）
  - 推定 `tokens/sec` 約 61.4
  - VRAM 目安: 約 5-6%

## 6. G4/K1 観測ログの命名規則（最終運用）

`g4-k1-single-shape-loop.sh` を使う場合、`RUN_TAG` を基準に命名を揃える。

- 実行例:

```bash
cd /home/limonene/ROCm-project/ROCm-MI25-build
RUN_TAG=k1_entry_20260325_1shape ./g4-k1-single-shape-loop.sh
```

- 主要出力:
  - `g4_k1_single_shape_loop_<RUN_TAG>.txt`
  - `g4_k1_single_shape_loop_<RUN_TAG>.tsv`
  - `g4_k1_single_shape_loop_<RUN_TAG>_index.tsv`

- canonical 証跡（lane別）:
  - `g4_k1_<RUN_TAG>_aets_link_summary.txt`
  - `g4_k1_<RUN_TAG>_system_link_summary.txt`
  - `g4_k1_<RUN_TAG>_<lane>_strace_summary.txt`
  - `g4_k1_<RUN_TAG>_<lane>_rocprof_summary.txt`
  - `g4_k1_<RUN_TAG>_aets_rocblas_gemm_shapes.tsv`（system は shape 観測 0 の場合は未生成）

## 7. 1shape 入口ループの扱い

- 入口ループは「最小 A/B」のみを行う。
  - 変更点は `ROCBLAS_TENSILE_LIBPATH` のみ（one-point change）。
  - workload 条件は固定（anchor）。
- 出力の解釈:
  - `fallback/dispatch/direct` は観測ラベル
  - `shape_target_hits` は対象 shape の再現確認
  - `ttft/total/tok_s` は運用比較指標
- 禁止:
  - この段階で solver/kernel の 1:1 因果を断定しない。

## 8. 1shape 反復観測の集約

`RUN_TAG` を同一 root で揃えた反復（例: `...`, `..._rerun1`, `..._rerun2`）は、
次の補助で lane 集約する。

```bash
cd /home/limonene/ROCm-project/ROCm-MI25-build
RUN_ROOT=k1_entry_20260325_1shape ./summarize-k1-single-shape-repeats.sh
```

出力:

- `g4_k1_single_shape_repeat_summary_<RUN_ROOT>_<TS>.txt`
- `g4_k1_single_shape_repeat_summary_<RUN_ROOT>_<TS>.tsv`
- `g4_k1_single_shape_repeat_detail_<RUN_ROOT>_<TS>.tsv`

確認ポイント:

- `fallback/dispatch/direct` が lane 内で `all_same=1` か
- `shape_hits_mode` が lane 内で固定か
- `ttft/total/tok_s` の平均と min/max が実運用で許容か
