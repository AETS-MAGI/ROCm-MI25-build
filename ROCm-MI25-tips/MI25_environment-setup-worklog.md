# MI25 / gfx900 環境構築 作業ログ

このファイルは実作業ログ専用です。
`MI25_environment-setup.md` は手順書として維持し、観測結果や暫定結論は本ファイルに集約します。

## 0. 読み方

- 本ログは時系列で追えるように、古い切り分けから新しい実測まで順番に記録しています。
- 章タイトルの末尾ラベルで情報源を区別します。
  - `[historical]`: 当時の切り分け時点の記録
  - `[main-node confirmed]`: 今回の実測で確認した事実
  - `[inference]`: 観測に基づく推定（未確定を含む）

---

## 1. 初期切り分け時点の事実と未確認 [historical]

### 1.1 事実（確認済み）

- ROCm 7.2 の導入手順で `rocminfo` / `rocm-smi` の認識を確認。
- `rocminfo` に `gfx900` と MI25 名称が出る。
- `rocm-smi` にMI25系デバイスが出る。
- Ollama user service は `active`。
- Ollama API (`/api/version`, `/api/tags`) は応答する。
- Ollama source build (`v0.18.2`, `gfx900` 指定) は成功。
- user service の `ExecStart` を source build バイナリ (`/home/user/ROCm-project/ollama-src/ollama`) に固定できる。
- Ollamaログに `failure during GPU discovery` と `library=cpu` が出る。
- 手動起動の切り分け（`HIP_VISIBLE_DEVICES=0/1`, `OLLAMA_LLM_LIBRARY=rocm`）でも CPU 判定だった。
- `build/lib/ollama` の参照不整合を直すと `initial_count=1` まで進むが、runner 初期化で `SIGABRT` が発生し GPU が最終利用できない。
- `SIGABRT` 直前に `rocBLAS` 初期化ログがあり、`rocblas/library` の `gfx900` 資産探索で `ENOENT` が連続する事実を確認。
- runner 単体再現でも `rocBLAS` の Tensile 読み込み失敗メッセージが明示され、`serve` ラッパ層ではなく runner/rocBLAS 初期化層での失敗が主因候補として強化された。

### 1.2 未確認（推測しない）

- source build 後に、実際の推論処理が GPU にオフロードできる条件の特定。
- runner の `SIGABRT` の直接原因（どの ROCm/hip 呼び出しで abort しているか）の特定。
- `rocBLAS` が `gfx900` 資産欠落時にどの条件で abort するか（エラーハンドリング仕様）の特定。
- `ollama pull` 後のモデル永続状態の最終確認（`ollama list` での確証取得が未完）。
- Ollama/ggml 側で gfx900 を実運用にするための最小追加パッチ。

---

## 2. 文書化ポリシーの更新メモ [historical]

- ROCmでのGPU可視性確認と、Ollamaでの計算実行確認を分離して記述。
- `GPUが見える` と `GPUで計算している` を別判定に統一。
- Ollama の service 運用で起きる権限問題・競合問題の再現条件と対処を整理。
- gfx900 source build 成功と、CPUフォールバック継続を同時に明記。

---

## 3. 参照した主要メモ / ファイル名 [historical]

- `MI25_environment-setup.md`
- `work_logs.md`
- `what_can_be_extended.md`
- `support_boundary.md`
- `facts.md`
- `knowns_unknowns.md`
- `vega-rocm.md`

---

## 4. 追加証拠の採取コマンド [historical]

```bash
# 1) ROCmデバイス可視性
rocminfo | rg -n "gfx900|Marketing Name|Agent"
rocm-smi

# 2) Ollama実行主体と競合確認
systemctl --user status ollama --no-pager
sudo systemctl status ollama --no-pager
ps -ef | rg -n "[o]llama serve|[o]llama runner"

# 3) GPU利用判定ログ
journalctl --user -u ollama --no-pager -n 300 | rg -n "discovering available GPUs|failure during GPU discovery|inference compute|library=" -i

# 4) モデル保存先の権限確認
namei -l /home/user/ROCm-project/ollama-models
ls -ld /home/user/ROCm-project/ollama-models

# 5) source build確認
rg -n "GPU_TARGETS|AMDGPU_TARGETS" /home/user/ROCm-project/ollama-src/build-gfx900/CMakeCache.txt
ls -lh /home/user/ROCm-project/ollama-src/build-gfx900/lib/ollama/libggml-hip.so

# 6) rocBLAS の gfx900 資産有無確認
ls -1 /opt/rocm-7.2.0/lib/rocblas/library | rg -n "gfx900|TensileLibrary(_lazy)?_gfx900|Kernels\\.so-.*gfx900" -i

# 7) runner 単体（serve 非経由）再現
env OLLAMA_DEBUG=1 OLLAMA_LLM_LIBRARY=rocm \
  OLLAMA_LIBRARY_PATH=/home/user/ROCm-project/ollama-src/build/lib/ollama \
  LD_LIBRARY_PATH=/home/user/ROCm-project/ollama-src/build/lib/ollama \
  HIP_VISIBLE_DEVICES=0 HSA_OVERRIDE_GFX_VERSION=9.0.0 \
  GGML_CUDA_INIT=1 ROCR_VISIBLE_DEVICES=<GPU-UUID> \
  /home/user/ROCm-project/ollama-src/ollama runner --ollama-engine --port 12601

curl -sv http://127.0.0.1:12601/info
```

---

## 5. 参照ノートとの照合メモ [historical]

- `ROCm-vega` には「過去観測では rocBLAS の gfx900 出荷資産が厚かった」記述が残る。
- 今回の実機再現（ROCm 7.2.0 apt）では `rocblas/library` に `gfx900` 向け Tensile/Kernels 資産が見当たらず、runner で `rocBLAS error` が直接出る。
- `ROCm-build` 側の MIOpen debug build は `rocblas_DIR=/opt/rocm/lib/cmake/rocblas` を参照しており、現行ランタイム資産の影響を受ける構成である。

---

## 6. セッション復旧メモ（2026-03-20）[main-node confirmed]

- 作業ルート統一方針: ROCm ローカル clone の既定先を `ROCm-repos_AETS` に統一。
- 実体確認結果: `rocBLAS` / `Tensile` はすでに `ROCm-repos_AETS` 配下に存在し、旧 `ROCm-repos` 直下には存在しない。
- スクリプト既定値更新:
  - `ROCm-vega/tools/open_wdblack_rocm_shell.sh`
  - `ROCm-vega/tools/bootstrap_rocm_repos_wdblack.sh`
  - `ROCm-vega/tools/sync_rocm_repo_to_wdblack.sh`
    以上 3 本の `DST_ROOT` / `WD_REPO_ROOT` 既定値を `/home/$USER/ROCm-project/ROCm-repos_AETS` 側へ更新。

確認コマンド:

```bash
cd /home/$USER/ROCm-project
ls -d ROCm-repos_AETS/rocBLAS ROCm-repos_AETS/Tensile
bash ROCm-vega/tools/open_wdblack_rocm_shell.sh --print
```

---

## 7. 最終認定試験ログ（2026-03-20）[main-node confirmed]

### 7.1 実施内容

- AETS 側で `rocBLAS + Tensile(gfx900)` を自前ビルド。
- `ROCBLAS_TENSILE_LIBPATH` を user service (`ollama`) に注入。
- `tinyllama` を pull して、`/api/generate` を 1 本実行。
- 生成中に `rocm-smi` を 1 秒間隔で採取。

### 7.2 確認できた事実

- service 環境に `ROCBLAS_TENSILE_LIBPATH` が設定されている。
- `journalctl` に `library=ROCm` かつ `compute=gfx900`、`Radeon Instinct MI25` が記録された。
- 生成リクエストは完了し、JSON レスポンスを取得できた。
- 生成中 `rocm-smi` で MI25 側の負荷上昇を確認:
  - `GPU use`: 最大 88-89%
  - `Socket Power`: 最大 201W
  - `VRAM`: 5-6% 使用

### 7.3 証跡ファイル

- `vega_path_check_logs/rocblas_gfx900_build_retry_20260320_171312.log`
- `vega_path_check_logs/ollama_generate_20260320_174327.json`
- `vega_path_check_logs/rocm_smi_during_generate_20260320_174327.log`
- `vega_path_check_logs/ollama_journal_after_test_20260320_174327.log`

### 7.4 判定

- 「GPU discovery 成功」だけでなく、少なくとも 1 回の生成リクエストで MI25(gfx900) 実行が観測できた。
- これにより、従来の「即 CPU fallback」状態から脱却したと判断できる。

---

## 8. 状態更新メモ（2026-03-20 追記）[main-node confirmed]

本節は、上記 7 章の証跡に基づく更新のみを記録する。

### 8.1 以前の未確認事項から今回解消できた範囲

- 「実際の生成処理で GPU が使われるか」は、少なくとも 1 リクエスト分は確認できた。
- `ROCBLAS_TENSILE_LIBPATH` 注入後に `library=ROCm` / `compute=gfx900` / `Radeon Instinct MI25` が同一検証系で確認できた。

### 8.2 依然として未確定の範囲

- 複数モデルでの再現性。
- 長時間運用時の安定性。
- 別マシンへ同手順を移植した場合の成功率。

### 8.3 この更新で追加した主証跡（ファイル名）

- `rocblas_gfx900_build_retry_20260320_171312.log`
- `ollama_generate_20260320_174327.json`
- `rocm_smi_during_generate_20260320_174327.log`
- `ollama_journal_after_test_20260320_174327.log`

---

## 9. tinyllama 経路安定性チェック（2026-03-20 夜）[main-node confirmed]

### 9.1 重要な観測結果

- `tinyllama:latest` について、以下 2 種類の回が同居することを再確認。
  - 以前の成功回: `library=ROCm` / `compute=gfx900` / `Radeon Instinct MI25` が出る回。
  - 今回の再実行回: service restart 後の初回・2回目とも CPU 経路に寄る回。
- よって「14B が重いから失敗」ではなく、まず GPU 経路の再現性が不安定であることが主問題。

### 9.2 今回の採取手順（固定化）

- user service を `systemctl --user restart ollama`。
- `tinyllama` で 1回目 generate。
- 同条件で 2回目 generate。
- 各 generate 中に `rocm-smi` を 1 秒間隔で採取。
- 各 phase で `journalctl --user -u ollama` を切り出し、`inference compute` / `library=*` / `GPULayers` を確認。

### 9.3 今回の採取結果（要点）

- 1回目・2回目とも、journal で `GPULayers:[]` が記録され GPUレイヤ割当が行われていない。
- `rocm-smi` では `GPU use (%)` が 0% 優勢（少なくとも抜粋範囲では上昇を確認できず）。
- 生成自体は完了するため、機能停止ではなく CPU fallback の再現事象として扱う。

### 9.4 追加証跡（ファイル名）

- `tinyllama_path_summary_20260320_192857.txt`
- `tinyllama_generate_first_20260320_192857.json`
- `tinyllama_generate_second_20260320_192857.json`
- `tinyllama_journal_first_20260320_192857.log`
- `tinyllama_journal_second_20260320_192857.log`
- `tinyllama_rocm_smi_first_20260320_192857.log`
- `tinyllama_rocm_smi_second_20260320_192857.log`

### 9.5 当面の優先順

1. `tinyllama` で restart 後も GPU 経路を安定再現できる条件を固定。
2. その固定条件で `deepseek-r1:14b` を検証。
3. 失敗原因を「モデル由来」と「経路不安定由来」に分離して記録。

---

## 10. A/B 実行モード追加（2026-03-20 夜）[main-node confirmed]

### 10.1 実装内容

- `tinyllama-gpu-path-check.sh` を `ROCm-MI25-build` 配下へ配置。
- 3軸比較の A/B モードを追加:
  - restart あり/なし
  - warm-up あり/なし
  - keep_alive `0s` / `10m`
- 各ケースで `first` / `second` を採取し、以下を自動出力:
  - JSON
  - journal 抜粋
  - `rocm-smi` 抜粋
  - 判定 (`GPU` / `CPU` / `MIXED` / `UNSURE`)
  - index TSV

### 10.2 スモーク実行（baseline 1ケース）

- 実行条件: `AB_ENABLE=0 NUM_PREDICT=64`
- 結果:
  - `baseline:first` -> `CPU`, `max_gpu_use=0`
  - `baseline:second` -> `CPU`, `max_gpu_use=0`
- journal 上でも `GPULayers:[]` と `device=CPU` が確認され、判定と整合。

### 10.3 追加証跡（ファイル名）

- `tinyllama_path_summary_20260320_193549.txt`
- `tinyllama_path_index_20260320_193549.tsv`
- `tinyllama_generate_baseline_first_20260320_193549.json`
- `tinyllama_generate_baseline_second_20260320_193549.json`
- `tinyllama_journal_baseline_first_20260320_193549.log`
- `tinyllama_journal_baseline_second_20260320_193549.log`
- `tinyllama_rocm_smi_baseline_first_20260320_193549.log`
- `tinyllama_rocm_smi_baseline_second_20260320_193549.log`

---

## 11. 追加切り分けと再評価（2026-03-20 夜）[main-node confirmed]

### 11.1 直接原因として確認できた事項

- `OLLAMA_LIBRARY_PATH=/home/limonene/ROCm-project/ollama-src/build/lib/ollama` 自体は設定されていた。
- ただし一時点でこのパス配下の backend 実体（`libggml-hip.so` など）が欠落しており、runner 単体ログでも backend search path 不在メッセージを確認。
- この状態では service restart 後に `inference compute library=cpu` へ直行する回が出る。

### 11.2 復旧操作

- `build-ollama-gfx900.sh` を再実行し、`build-gfx900/lib/ollama` を再生成。
- 再生成後に `libggml-hip.so` を含む backend ライブラリ群の存在を確認。

### 11.3 復旧後 baseline 再試験

- 実行条件: `AB_ENABLE=0 NUM_PREDICT=64`
- 結果:
  - `baseline:first`: `inference_library=ROCm`, `inference_compute=gfx900`, `GPULayers:23`
  - `baseline:second`: `max_gpu_use=91`, `offloaded 23/23 layers to GPU`
- `device=CPU` / `GPULayers:[]` 固定とは矛盾し、GPU経路復帰を確認。

### 11.4 復旧後 full A/B（8ケース）

- 実行条件: `NUM_PREDICT=96`
- 結果サマリ（16 phase）:
  - `GPU`: 15
  - `UNSURE`: 1（`r1_w0_k1` の second）
- case 別では全ケースで少なくとも 1 phase は GPU 判定。
- 特に `r0_*` 系はすべて `GPU/GPU` で完走。

### 11.5 重要な更新結論 [inference]

- 直前に見えていた「restart 後は常時 CPU fallback」傾向は、backend 実体欠落時の挙動が強く混ざっていた可能性が高い。
- 復旧後は `restart=1` を含む多数ケースで `library=ROCm` / `GPULayers:23` / 高い `GPU use` が再観測された。
- よって現時点は「MI25 経路が不可能」ではなく、「backend 配備状態が崩れると CPU fallback へ倒れる」という管理課題として扱うのが妥当。

### 11.6 この更新の主証跡

- `build_ollama_gfx900_recover_20260320_194954.log`
- `tinyllama_path_summary_20260320_195645.txt`
- `tinyllama_path_index_20260320_195645.tsv`
- `tinyllama_path_summary_20260320_195741.txt`
- `tinyllama_path_index_20260320_195741.tsv`

---

## 12. deepseek-r1:14b 実測（2026-03-20 夜）[main-node confirmed]

### 12.1 前提

- backend 実体（`libggml-hip.so` など）復旧後の同一サービス構成で検証。
- user service restart 後に `deepseek-r1:14b` を generate し、`journalctl` と `rocm-smi` を同時採取。

### 12.2 結果

- generate 完了:
  - `model=deepseek-r1:14b`
  - `done=true`
  - `done_reason=length`
  - `eval_count=140`
- journal で GPU 経路を確認:
  - `inference compute ... library=ROCm compute=gfx900`
  - `Radeon Instinct MI25`
  - `GPULayers:49`
  - `offloaded 49/49 layers to GPU`
- `rocm-smi` で高負荷を確認:
  - `GPU use`: 最大 99%
  - `Socket Power`: 200W 超級（最大 217W 観測）
  - `VRAM`: 約 58%

### 12.3 判定

- `deepseek-r1:14b` でも MI25(gfx900) 上で ROCm 経路の実推論が成立することを確認。
- これにより「tinyllama 限定でのみ成功」ではなく、上位モデルまで GPU 実行可能であることを実証。

### 12.4 証跡

- `vega_path_check_logs/deepseek14b_generate_20260320_212146.json`
- `vega_path_check_logs/deepseek14b_journal_20260320_212146.log`
- `vega_path_check_logs/deepseek14b_rocm_smi_20260320_212146.log`
- `assets/screen_shot-gfx900-deepseek-r1.png`

---

## 13. 証跡インデックス（要約）[main-node confirmed]

### 13.1 tinyllama A/B

- `tinyllama_path_index_20260320_195741.tsv`
- `tinyllama_path_index_20260320_200424.tsv`
- `tinyllama_path_summary_20260320_195741.txt`
- `tinyllama_path_summary_20260320_200424.txt`

### 13.2 deepseek-r1:14b

- `deepseek14b_generate_20260320_212146.json`
- `deepseek14b_journal_20260320_212146.log`
- `deepseek14b_rocm_smi_20260320_212146.log`
- `assets/screen_shot-gfx900-deepseek-r1.png`

### 13.3 復旧手順関連

- `build_ollama_gfx900_recover_20260320_194954.log`
- `rocblas_gfx900_build_retry_20260320_171312.log`

---

## 14. モデル評価メモ（2026-03-21）[main-node confirmed]

### 14.1 deepseek-r1:14b の template / reasoning 表示確認

- `ollama show --modelfile deepseek-r1:14b` で `<think>...</think>` を含む TEMPLATE を確認。
- `/api/generate` で `think=true` の場合は `thinking` フィールドが返る。
- `/api/generate` で `think=false` の場合は `thinking` が返らず、`response` のみ返る。
- 以上より、`Thinking...` 表示はモデルテンプレートと API 側の think 設定に依存する挙動と判断。

### 14.2 日本語出力の簡易品質確認

- deepseek (`think=false`) は日本語2文の技術説明を生成可能。
- ただし軽微な語彙崩れ（例: `ibraries`）が混ざる回があり、最終用途では整文または後処理が必要。
- qwen2.5:7b は短文日本語の自然さは良好で、要約用途に使いやすい。

### 14.3 追加モデル試験（qwen2.5:7b）

- 実施: `ollama pull qwen2.5:7b` 後、共通チェッカーで generate / journal / rocm-smi を採取。
- journal:
  - `library=ROCm`
  - `compute=gfx900`
  - `GPULayers:29`
  - `offloaded 29/29 layers to GPU`
- rocm-smi:
  - `GPU use`: 最大 100%
  - `Socket Power`: 最大 216W
  - `VRAM`: 最大 31%

### 14.4 モデル帯の暫定整理（MI25 16GB）

- 軽量帯（~1B）: `tinyllama` は高速（約 61 tok/s 目安）で動作確認向け。
- 中量帯（~7B）: `qwen2.5:7b` は VRAM 31% 前後、約 13 tok/s で実用候補。
- 上位帯（~14B）: `deepseek-r1:14b` は VRAM 58% 前後、約 15 tok/s、ROCm/gfx900 で実運用可能。
- 16GB 前提では、まず 7B〜14B を主運用帯として扱うのが妥当。

### 14.5 この更新の主証跡

- `vega_path_check_logs/model_generate_deepseek-r1_14b_20260321_012715.json`
- `vega_path_check_logs/model_journal_deepseek-r1_14b_20260321_012715.log`
- `vega_path_check_logs/model_rocm_smi_deepseek-r1_14b_20260321_012715.log`
- `vega_path_check_logs/model_generate_qwen2.5_7b_20260321_020642.json`
- `vega_path_check_logs/model_journal_qwen2.5_7b_20260321_020642.log`
- `vega_path_check_logs/model_rocm_smi_qwen2.5_7b_20260321_020642.log`

---

## 15. gpt-oss:latest（20.9B）検証（2026-03-21）[main-node confirmed]

### 15.1 実施内容

- `ollama show gpt-oss:latest` で `parameters=20.9B` を確認。
- 共通チェッカーで `generate / journal / rocm-smi` を同時採取。
- 追加で `think=false` API 呼び出しを実施し、出力形状を確認。

### 15.2 GPU 経路の確認結果

- journal:
  - `library=ROCm`
  - `Radeon Instinct MI25 (gfx900)`
  - `GPULayers:25`
  - `offloaded 25/25 layers to GPU`
- rocm-smi:
  - `GPU use`: 最大 100%
  - `Socket Power`: 最大 220W
  - `VRAM`: 最大 77%

### 15.3 生成挙動の観測

- `stream=false` 実行で `done=true`, `done_reason=length`, `eval_count=180` を確認。
- ただし `response` が空文字で、`thinking` のみ返る回を再現（`think=false` 指定時も同様）。
- よって現時点では「GPU 推論経路は成立」だが「最終テキスト応答の安定取得」は要追加確認。

### 15.4 暫定評価

- MI25 16GB で 20B 級モデルのロードと GPU offload は可能。
- 一方で出力制御はモデルテンプレート/ランタイム実装依存の挙動差があり、運用前に応答取り出し条件の固定が必要。

### 15.5 この更新の主証跡

- `vega_path_check_logs/model_generate_gpt-oss_latest_20260321_031355.json`
- `vega_path_check_logs/model_journal_gpt-oss_latest_20260321_031355.log`
- `vega_path_check_logs/model_rocm_smi_gpt-oss_latest_20260321_031355.log`
