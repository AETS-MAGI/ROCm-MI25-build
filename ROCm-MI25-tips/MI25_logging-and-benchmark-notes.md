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
