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

---

## 16. G4 fallback_confirmed 達成（2026-03-24）[main-node confirmed]

### 16.1 目的

- `safe` 基準固定後の最終ゲートとして、実機 runtime で fallback 経路を最低1件確定する。
- 文字列ベース（`falling back`）だけに依存せず、実際の runtime 資産アクセスで判定する。

### 16.2 実施

- 追加スクリプト:
  - `g4-fallback-strace-check.sh`
- 手順:
  - `ollama serve` を別ポート（`127.0.0.1:11534`）で一時起動
  - `strace -ff -e trace=openat,openat2` で file open を採取
  - `tinyllama:latest` を non-stream 実行
  - `TensileLibrary_*_fallback.dat/.hsaco` の openat 件数を集計

### 16.3 判定

- `fallback_dat_openat=54`
- `fallback_hsaco_openat=54`
- よって、`fallback_confirmed` を **達成** と判定。

補足:
- 現行 Ollama journal に `falling back` 明示文字列は未観測。
- ただし gate 判定は runtime fallback 資産アクセスにより満たした。

### 16.4 主証跡

- `vega_path_check_logs/g4_summary_tinyllama_latest_20260324_005717.txt`
- `vega_path_check_logs/g4_generate_tinyllama_latest_20260324_005717.json`
- `vega_path_check_logs/g4_serve_stderr_tinyllama_latest_20260324_005717.log`
- `vega_path_check_logs/g4_strace_openat_tinyllama_latest_20260324_005717.log*`

### 16.5 観測メモ

- `libggml-hip.so` の openat を確認（HIP backend）。
- `librocblas.so.5` は `/opt/rocm-7.2.0/lib` から解決。
- `ROCBLAS_TENSILE_LIBPATH` はローカル fork（`ROCm-repos_AETS/rocBLAS/.../rocblas/library`）を参照し、
  `TensileLibrary_*_fallback.dat/.hsaco` の実アクセスを確認。

---

## 17. fallback 型別集計の追加（2026-03-24）[main-node confirmed]

### 17.1 目的

- G4 で確認した `fallback_confirmed` を、型別（`Type_HH` など）に分解して記録する。
- 次段の dispatch 切り分けの土台を作る。

### 17.2 実施

- 追加スクリプト:
  - `summarize-fallback-types.sh`
- 対象ログ:
  - `vega_path_check_logs/g4_strace_openat_tinyllama_latest_20260324_005717.log.*`
- 出力:
  - `vega_path_check_logs/fallback_type_summary_tinyllama_20260324.txt`

### 17.3 集計結果（抜粋）

- `matched_lines=108`（`.dat` 54 + `.hsaco` 54）
- 型別上位:
  - `Type_CC: 18`
  - `Type_ZZ: 18`
  - `Type_HH: 8`
  - `Type_HS_HPA: 8`
  - `Type_HH_HPA: 8`

### 17.4 注意点

- 上記は **catalog read の型分布** であり、dispatch の直接証跡ではない。
- ただし、`fallback` 資産が `dat/hsaco` の両方で型別に読み込まれていることは確認できた。

---

## 18. fallback 時系列分解 + rocBLAS trace 追加（2026-03-24）[main-node confirmed]

### 18.1 目的

- `fallback_confirmed`（catalog read）から一歩進めて、`catalog` と `dispatch` の境界を観測する。
- 「いつ読まれたか」を定量化し、初期化バーストと実行中アクセスを切り分ける。

### 18.2 実施

- `g4-fallback-strace-check.sh` を拡張:
  - `STRACE_TIMESTAMP=1`（既定）で `strace -tt` を有効化
  - `PROBE_ROCBLAS_LOG=1` で `ROCBLAS_LOG_TRACE_PATH` 等を有効化
  - summary に `rocblas_trace_*` カウンタを追記
- 追加スクリプト:
  - `summarize-fallback-phases.sh`
  - `.dat/.hsaco` の `first/last time` と span を pid単位で集計

### 18.3 観測結果（tinyllama latest）

- summary:
  - `vega_path_check_logs/g4_summary_tinyllama_latest_20260324_014707.txt`
  - `rocblas_trace_lines=1`
  - `rocblas_trace_handle_lines=1`
  - `rocblas_trace_gemm_lines=0`
- phase summary:
  - `vega_path_check_logs/fallback_phase_summary_tinyllama_latest_20260324_014707.tsv`
  - `.dat` 読み込み: span `0.035186s`（短いバースト）
  - `.hsaco` 読み込み: span `1.302794s`（より長い分布）

### 18.4 判定

- 時系列上、`.dat` は初期化寄りの集中読み込みとして整合。
- `.hsaco` はより広い時間帯に分布し、実行段での関与可能性は上がった。
- ただし `rocBLAS` trace は現時点で `create_handle` のみで、GEMM 呼び出し行は未観測。
- よって、dispatch 直接証跡の最終確定は **継続タスク**。

追試:

- `ROCBLAS_LAYER=63` でも `rocblas_trace_gemm_lines=0`（`g4_summary_tinyllama_latest_20260324_015056.txt`）。

### 18.5 主証跡

- `g4-fallback-strace-check.sh`
- `summarize-fallback-phases.sh`
- `vega_path_check_logs/g4_summary_tinyllama_latest_20260324_014707.txt`
- `vega_path_check_logs/g4_summary_tinyllama_latest_20260324_015056.txt`
- `vega_path_check_logs/fallback_phase_summary_tinyllama_latest_20260324_014707.tsv`
- `vega_path_check_logs/g4_rocblas_trace_tinyllama_latest_20260324_014707.log`

---

## 19. rocprofv3 dispatch probe 追加（2026-03-24）[main-node confirmed]

### 19.1 目的

- `strace(openat)` では見えない「実際に dispatch された GPU kernel」を取得する。
- `catalog read` と `dispatch` を分離し、dispatch 側の直接証跡を補強する。

### 19.2 実施

- 追加スクリプト:
  - `g4-rocprofv3-dispatch-check.sh`
- 手順:
  - 専用ポート（`127.0.0.1:11634`）で `ollama serve` を一時起動
  - `rocprofv3 --runtime-trace --kernel-trace -f csv` で trace 採取
  - `tinyllama:latest` を短い non-stream 生成で 1 回実行
  - `kernel_trace.csv` を集計し、top kernel とカウンタを summary 化

### 19.3 観測結果（tinyllama latest）

- summary:
  - `vega_path_check_logs/rocprofv3_summary_tinyllama_latest_20260324_020034.txt`
- 主なカウンタ:
  - `kernel_dispatch_rows=3605`
  - `kernel_mul_mat_q_rows=151`
  - `kernel_mul_mat_vec_rows=934`
  - `kernel_flash_attn_rows=352`
  - `kernel_quantize_rows=1085`
  - `kernel_tensile_like_rows=0`
- 代表 kernel（抜粋）:
  - `mul_mat_q<(ggml_type)2,...>`
  - `mul_mat_vec_q<(ggml_type)2,...>`
  - `flash_attn_tile<...>`
  - `quantize_q8_1(...)`

### 19.4 判定

- dispatch 直接証跡（kernel trace）は取得に成功。
- ただし今回の trace は **ggml-hip 側 kernel が中心** で、`rocBLAS/Tensile` 名を含む dispatch は未観測。
- よって「dispatch 証跡ゼロ」状態は解消されたが、
  「fallback 資産（Tensile）と同一 run での dispatch 直結」は継続課題。

### 19.5 主証跡

- `g4-rocprofv3-dispatch-check.sh`
- `vega_path_check_logs/rocprofv3_summary_tinyllama_latest_20260324_020034.txt`
- `vega_path_check_logs/rocprofv3_probe_tinyllama_latest_20260324_020034/`
- `vega_path_check_logs/rocprofv3_generate_tinyllama_latest_20260324_020034.json`

---

## 20. fallback+dispatch 統合判定スクリプト追加（2026-03-24）[main-node confirmed]

### 20.1 目的

- `strace` 側（fallback 資産アクセス）と `rocprofv3` 側（kernel dispatch）を
  **同一条件で連続実行**し、1つの判定ファイルで管理する。
- 「証跡はあるが別 run」という分断を減らし、Phase 2 の残務を機械的に回せる形にする。

### 20.2 実施

- 追加スクリプト:
  - `g4-fallback-dispatch-link-check.sh`
- 実行内容:
  1. `g4-fallback-strace-check.sh`（`PROBE_ROCBLAS_LOG=1`）
  2. `g4-rocprofv3-dispatch-check.sh`
  3. 上記2本の summary を統合し、`g4_link_summary_*` を生成

### 20.3 実測結果（tinyllama latest）

- 統合 summary:
  - `vega_path_check_logs/g4_link_summary_tinyllama_latest_20260324_020803.txt`
- 主要値:
  - fallback 側:
    - `libggml_hip_openat=4`
    - `fallback_dat_openat=54`
    - `fallback_hsaco_openat=54`
    - `rocblas_trace_gemm_lines=0`
  - dispatch 側:
    - `kernel_dispatch_rows=22773`
    - `kernel_tensile_like_rows=0`
  - gate:
    - `fallback_confirmed=1`
    - `dispatch_confirmed=1`
    - `direct_rocblas_or_tensile_dispatch=0`
    - `link_status=indirect_link_only_same_scenario`

### 20.4 判定

- fallback 証跡と dispatch 証跡を同一条件 run として束ねるところまでは達成。
- ただし現時点では `rocBLAS/Tensile` 名の dispatch は未観測で、direct link は未達。
- 次段は、同スクリプトを使ってモデル/問題サイズ条件を振り、`direct_rocblas_or_tensile_dispatch=1` を狙う。

### 20.5 主証跡

- `g4-fallback-dispatch-link-check.sh`
- `vega_path_check_logs/g4_link_summary_tinyllama_latest_20260324_020803.txt`
- `vega_path_check_logs/g4_summary_tinyllama_latest_20260324_020804.txt`
- `vega_path_check_logs/rocprofv3_summary_tinyllama_latest_20260324_020811.txt`

### 20.6 追試（qwen2.5:7b）

- 統合 summary:
  - `vega_path_check_logs/g4_link_summary_qwen2.5_7b_20260324_021010.txt`
- 主要値:
  - `fallback_confirmed=1`
  - `dispatch_confirmed=1`
  - `direct_rocblas_or_tensile_dispatch=0`
  - `rocblas_trace_gemm_lines=0`
  - `kernel_tensile_like_rows=0`
  - `link_status=indirect_link_only_same_scenario`

追試判定:

- tinyllama と同じ判定に収束したため、現時点の未達はモデル個別の偶然より
  「rocBLAS/Tensile 名 dispatch を捕まえる観測粒度」の課題と判断する。

---

## 21. ROCBLAS_LAYER / trace 粒度スイープ（2026-03-24）[main-node confirmed]

### 21.1 目的

- `direct_rocblas_or_tensile_dispatch` 未達の原因を切り分けるため、
  `ROCBLAS_LAYER` の観測粒度を先に確定する。
- 同時に「どの layer が最も情報を出すか」を runbook 化する。

### 21.2 実施

- 追加スクリプト:
  - `g4-rocblas-layer-sweep.sh`
- 実施条件:
  - `LAYER_LIST=1,8,9,15,63`
  - model: `tinyllama:latest`, `qwen2.5:7b`
  - `PROBE_ROCBLAS_LOG=1`（内部で有効化）

### 21.3 結果（要約）

- tinyllama:
  - `g4_rocblas_layer_sweep_tinyllama_latest_20260324_021652.txt`
- qwen:
  - `g4_rocblas_layer_sweep_qwen2.5_7b_20260324_021747.txt`

共通結果:

- `layer=8` 単体は trace 行が 0（内部 API ログ単体では有効行なし）
- `layer=1/9/15/63` は `rocblas_create_handle` 1 行のみ
- `trace_gemm_lines=0`、`bench_lines=0`、`profile_lines=0`（両モデル共通）

### 21.4 暫定確定設定

- 観測既定値: `ROCBLAS_LAYER=9`（trace + internal）
  - 理由:
    - `layer=1` と同等の可視性を維持
    - かつ内部 API ログ経路（bit 8）を常時有効にできる
    - `63` より過剰なビットを避け、runbook を単純化できる
- これに合わせて `g4-fallback-strace-check.sh` の既定値を `9` に更新。

### 21.5 解釈

- 現行 GGUF run では、`ROCBLAS_LAYER` を変えても GEMM 呼び出し行は増えなかった。
- よって次段は「layer 値の探索」ではなく、
  **rocBLAS を実際に呼ぶ workload/演算経路を作ること**が主課題。

---

## 22. workload 条件スイープで direct dispatch を確定（2026-03-24）[main-node confirmed]

### 22.1 目的

- `ROCBLAS_LAYER=9` 固定後、model / prompt / `NUM_PREDICT` 側を振って
  `direct_rocblas_or_tensile_dispatch=1` を狙う。

### 22.2 実施

- スイープ（高演算密度）:
  - `g4-workload-path-sweep.sh`
  - `MODEL_LIST=qwen2.5:7b,deepseek-r1:14b`
  - `NUM_PREDICT_LIST=512`
  - `PROMPT_PROFILE_LIST=long,math,code`
- 追加単発検証:
  - `g4-fallback-dispatch-link-check.sh`
  - `MODEL=gpt-oss:latest`
  - `NUM_PREDICT=256`
  - `ROCBLAS_LAYER=9`

### 22.3 結果（要約）

- qwen/deepseek スイープ:
  - `vega_path_check_logs/g4_workload_path_sweep_20260324_023631.txt`
  - `ok_cases=6`, `failed_cases=0`, `direct_hits=0`
  - 全ケース `link_status=indirect_link_only_same_scenario`
- gpt-oss 単発:
  - `vega_path_check_logs/g4_link_summary_gpt-oss_latest_20260324_024249.txt`
  - `fallback_confirmed=1`
  - `dispatch_confirmed=1`
  - `direct_rocblas_or_tensile_dispatch=1`
  - `link_status=direct_rocblas_or_tensile_dispatch_observed`
  - `rocblas_trace_gemm_lines=1002`
  - `kernel_tensile_like_rows=167`

### 22.4 追加解析（shape 集計）

- 追加スクリプト:
  - `summarize-rocblas-gemm-shapes.sh`
- gpt-oss trace 集計:
  - `vega_path_check_logs/rocblas_gemm_shapes_g4_rocblas_trace_gpt-oss_latest_20260324_024249_20260324_024704.txt`
  - `gemm_api_lines=501`
  - `internal_tensile_lines=501`
  - 上位 shape:
    - `512x512x2880` (`rocblas_gemm_ex`, `rocblas_gemm_tensile_backend`)
    - `4096x512x64` / `64x512x4096` (`rocblas_gemm_batched_ex`)
    - `2880x512x4096`, `4096x512x2880` (`rocblas_gemm_ex`)

### 22.5 判定

- `ROCBLAS_LAYER` の問題ではなく workload 条件が分岐点だったことを確認。
- G4 の direct dispatch ゲートは **gpt-oss 条件で達成**。
- 次段は、この条件を基準ケースとして
  `rocblas_gemm_ex` / `rocblas_gemm_tensile_backend` の shape 分布を固定観測し、
  Tensile/rocBLAS 側の優先チューニング候補を絞る。

### 22.6 主証跡

- `vega_path_check_logs/g4_workload_path_sweep_20260324_023631.txt`
- `vega_path_check_logs/g4_link_summary_gpt-oss_latest_20260324_024249.txt`
- `vega_path_check_logs/g4_summary_gpt-oss_latest_20260324_024249.txt`
- `vega_path_check_logs/rocprofv3_summary_gpt-oss_latest_20260324_024321.txt`
- `vega_path_check_logs/rocblas_gemm_shapes_g4_rocblas_trace_gpt-oss_latest_20260324_024249_20260324_024704.tsv`

### 22.7 正式反映（事実 / 解釈 / 含意）

1. 事実
   - `gpt-oss:latest` 条件で `rocblas_gemm_ex` と
     `rocblas_gemm_tensile_backend` を多数観測。
   - `direct_rocblas_or_tensile_dispatch=1` を同一シナリオで確認。

2. 解釈
   - tinyllama / qwen2.5:7b では未観測だった direct dispatch 名が、
     workload を変えると観測された。
   - 未観測の主因は layer 設定より workload/path 条件である可能性が高い。

3. 含意
   - rocBLAS / Tensile direct dispatch を観測可能な probe 条件が確立した。
   - 今後はこの条件を基準ケースにして、
     model / precision / path 差分を比較可能。

---

## 23. rawログ分離と圧縮運用の導入（2026-03-24）[main-node confirmed]

### 23.1 背景

- `vega_path_check_logs/` のファイル件数増加により、
  git 操作と GitHub 上の閲覧が重くなってきた。
- 方針:
  - summary は repo 内 (`vega_path_check_logs/`)
  - raw/probe は repo 外 (`${WORKSPACE_ROOT}/vega_path_check_logs_raw`)

### 23.2 実施

- g4系スクリプトに `RAW_LOG_DIR` 既定値を追加し、
  raw 出力先を `${WORKSPACE_ROOT}/vega_path_check_logs_raw` へ分離:
  - `g4-fallback-strace-check.sh`
  - `g4-rocprofv3-dispatch-check.sh`
  - `g4-fallback-dispatch-link-check.sh`
  - `g4-workload-path-sweep.sh`
  - `g4-rocblas-layer-sweep.sh`
- 補助スクリプト追加:
  - `migrate-raw-logs.sh`（既存 raw の copy/move）
  - `compress-raw-logs.sh`（raw の gzip 管理）
- `.gitignore` 追加:
  - `vega_path_check_logs/` 配下の raw/probe 拡張子を追跡除外
  - summary (`*.txt`, `*.tsv`, `*.md`, `*.jsonl`) は追跡対象

### 23.3 運用上の注意

- `.gitignore` は「新規追跡の抑止」であり、既存履歴の縮小ではない。
- 履歴最適化（`filter-repo` 等）は、別フェーズ・別合意で実施する。

### 23.4 初回移行・圧縮実行（このノード）

- raw退避先:
  - `/home/$USER/ROCm-project/vega_path_check_logs_raw`
- 移行（copy, 非破壊）:
  - `migrate-raw-logs.sh`
  - `total_candidates=3738`, `done=3738`, `failed=0`
  - summary: `vega_path_check_logs/raw_log_migrate_summary_20260324_030759.txt`
- 圧縮（replace）:
  - `compress-raw-logs.sh` with `KEEP_ORIGINAL=0`
  - `total_candidates=3825`, `compressed=3756`, `replaced=3756`, `failed=0`
  - 追圧縮置換: `total_candidates=69`, `replaced=69`
  - summary:
    - `vega_path_check_logs/raw_log_compress_summary_20260324_030842.txt`
    - `vega_path_check_logs/raw_log_compress_summary_20260324_031003.txt`

---

## 24. gpt-oss アンカースイープ導入（2026-03-24）[main-node confirmed]

### 24.1 目的

- 方針を `gpt-oss:latest + ROCBLAS_LAYER=9` の観測アンカーへ固定し、
  runtime ノブを 1 つずつ振って direct dispatch の変化を比較可能にする。
- 上位 shape（`512x512x2880`, `4096x512x64`, `64x512x4096`,
  `2880x512x4096`, `4096x512x2880`）をケースごとに定量化する。

### 24.2 実装（スクリプト）

- 新規:
  - `g4-gptoss-anchor-shape-sweep.sh`
    - `g4-fallback-dispatch-link-check.sh` をケース行列で実行
    - target shape のヒット数を `rocBLAS` trace から集計
    - `*.tsv` と `*.txt` の集約 summary を出力
- 既存更新:
  - `g4-fallback-strace-check.sh`
  - `g4-rocprofv3-dispatch-check.sh`
  - `g4-fallback-dispatch-link-check.sh`
  - `g4-rocblas-layer-sweep.sh`
  - `g4-workload-path-sweep.sh`
- 追加した共通 runtime ノブ:
  - `NUM_CTX`
  - `NUM_BATCH`
  - `NUM_THREAD`
  - `KEEP_ALIVE`

### 24.3 検証（最小1ケース）

- コマンド:
  - `MODEL=tinyllama:latest NUM_PREDICT_LIST=16 NUM_CTX_LIST=2048 NUM_BATCH_LIST=256 KEEP_ALIVE_LIST=2m RUNS_PER_CASE=1 ./g4-gptoss-anchor-shape-sweep.sh`
- summary:
  - `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_tinyllama_latest_20260324_033423.txt`
- 結果:
  - `ok_cases=1`, `failed_cases=0`
  - `fallback_confirmed=1`, `dispatch_confirmed=1`
  - `direct_hits=0`（tinyllama は回帰確認用で想定どおり）

### 24.4 次段

- 本番観測条件:
  - `MODEL=gpt-oss:latest`
  - `ROCBLAS_LAYER=9`
  - target shape 固定
- 次に確認する指標:
  - `direct_rocblas_or_tensile_dispatch`
  - `rocblas_trace_gemm_lines`
  - target shape ごとのヒット総量（ケース比較）

### 24.5 gpt-oss アンカー1ケース実行（本番条件）

- コマンド:
  - `MODEL=gpt-oss:latest NUM_PREDICT_LIST=128 NUM_CTX_LIST=8192 NUM_BATCH_LIST=512 KEEP_ALIVE_LIST=5m RUNS_PER_CASE=1 ./g4-gptoss-anchor-shape-sweep.sh`
- summary:
  - `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260324_033556.txt`
- 結果（要約）:
  - `ok_cases=1`, `direct_hits=1`
  - `direct_rocblas_or_tensile_dispatch=1`
  - `rocblas_trace_gemm_lines=1002`
  - `kernel_tensile_like_rows=167`
  - target shape hits:
    - `512x512x2880 = 192`
    - `2880x512x4096 = 96`
    - `4096x512x2880 = 96`
    - `4096x512x64 = 0`
    - `64x512x4096 = 0`
- link summary:
  - `vega_path_check_logs/g4_link_summary_gpt-oss_latest_20260324_033556.txt`

### 24.6 `num_batch` 2ケース比較（512 vs 1024）

- コマンド:
  - `MODEL=gpt-oss:latest NUM_PREDICT_LIST=128 NUM_CTX_LIST=8192 NUM_BATCH_LIST=512,1024 KEEP_ALIVE_LIST=5m RUNS_PER_CASE=1 ./g4-gptoss-anchor-shape-sweep.sh`
- summary:
  - `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260324_033756.txt`
- 結果（要約）:
  - `ok_cases=2`, `direct_hits=2`
  - case-1 (`num_batch=512`):
    - `rocblas_trace_gemm_lines=1002`
    - target shape hits total `384`
  - case-2 (`num_batch=1024`):
    - `rocblas_trace_gemm_lines=1336`
    - 固定 target shape hits total `0`
- 追加 shape 解析（case-2 trace）:
  - `vega_path_check_logs/rocblas_gemm_shapes_g4_rocblas_trace_gpt-oss_latest_20260324_033849_20260324_034006.txt`
  - 上位 shape が `*x1024x*` へ移動:
    - `512x1024x2880`
    - `2880x1024x4096`
    - `4096x1024x2880`

解釈:

- `num_batch` 変更で direct dispatch は維持される一方、
  観測される主要 shape は明確に移動する。
- 次段では `target_shapes` を `num_batch` 条件ごとに分けるか、
  `N` 次元を可変扱いにした集計へ拡張する。

---

## 25. Anchor条件の正本化と baseline/side 分離（2026-03-24）[main-node confirmed]

### 25.1 正本化（Canonical profile）

- 新規: `ROCm-MI25-tips/G4_gptoss_anchor_profile.md`
- 目的:
  - `gpt-oss` 観測アンカー条件を正本化
  - baseline (`num_batch=512`) と side (`num_batch=1024`) を役割分離

正本 baseline:

- `MODEL=gpt-oss:latest`
- `ROCBLAS_LAYER=9`
- `NUM_CTX=8192`
- `NUM_BATCH=512`
- `NUM_PREDICT={64,128,256}`
- `KEEP_ALIVE=5m`

### 25.2 baseline sweep（`num_batch=512`）

- コマンド:
  - `MODEL=gpt-oss:latest NUM_PREDICT_LIST=64,128,256 NUM_CTX_LIST=8192 NUM_BATCH_LIST=512 KEEP_ALIVE_LIST=5m RUNS_PER_CASE=1 ./g4-gptoss-anchor-shape-sweep.sh`
- summary:
  - `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260324_034636.txt`
- 結果:
  - `ok_cases=3`, `direct_hits=3`
  - `rocblas_trace_gemm_lines=1002`（全3ケースで同値）
  - shape totals:
    - `512x512x2880=576`
    - `2880x512x4096=288`
    - `4096x512x2880=288`

### 25.3 side sweep（`num_batch=1024`）

- 旧 target（`*x512x*`）での確認:
  - `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260324_034917.txt`
  - `direct_hits=3` だが target hits は 0（shape 定義ミスマッチ）
- 1024-target へ切替して再実行:
  - `MODEL=gpt-oss:latest NUM_PREDICT_LIST=64,128,256 NUM_CTX_LIST=8192 NUM_BATCH_LIST=1024 TARGET_SHAPES='512x1024x2880,4096x1024x64,64x1024x4096,2880x1024x4096,4096x1024x2880' KEEP_ALIVE_LIST=5m RUNS_PER_CASE=1 ./g4-gptoss-anchor-shape-sweep.sh`
  - summary: `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260324_035250.txt`
- 結果:
  - `ok_cases=3`, `direct_hits=3`
  - `rocblas_trace_gemm_lines=1336`（全3ケースで同値）
  - shape totals:
    - `512x1024x2880=864`
    - `2880x1024x4096=432`
    - `4096x1024x2880=432`

### 25.4 判定

- 観測アンカーは `gpt-oss + layer=9 + ctx=8192 + batch=512` で固定してよい。
- `num_batch=1024` は direct dispatch を維持しつつ shape family を移動させる副系統として有効。
- 次段では baseline を既定比較軸、side を shape-shift 感度軸として併用する。

---

## 26. baseline512 で `num_ctx` 単独スイープ（2026-03-24）[main-node confirmed]

### 26.1 目的

- baseline (`num_batch=512`) を固定し、`num_ctx` だけを動かして
  上位3shapeヒット数と `rocblas_trace_gemm_lines` の感度を確認。

### 26.2 条件

- `MODEL=gpt-oss:latest`
- `NUM_PREDICT=128`
- `NUM_BATCH=512`
- `KEEP_ALIVE=5m`
- `NUM_CTX={4096,6144,8192,12288}`
- `TARGET_SHAPES=512x512x2880,2880x512x4096,4096x512x2880`

実行:

- `MODEL=gpt-oss:latest NUM_PREDICT_LIST=128 NUM_CTX_LIST=4096,6144,8192,12288 NUM_BATCH_LIST=512 TARGET_SHAPES='512x512x2880,2880x512x4096,4096x512x2880' KEEP_ALIVE_LIST=5m RUNS_PER_CASE=1 ./g4-gptoss-anchor-shape-sweep.sh`
- summary:
  - `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260324_040223.txt`
- comparison note:
  - `vega_path_check_logs/g4_baseline512_numctx_sweep_compare_20260324_040508.txt`

### 26.3 結果

- 4ケースすべて `direct_rocblas_or_tensile_dispatch=1`
- 4ケースすべて `rocblas_trace_gemm_lines=1002`
- 4ケースすべて shape ヒット数が同一:
  - `512x512x2880=192`
  - `2880x512x4096=96`
  - `4096x512x2880=96`

### 26.4 判定

- この範囲の `num_ctx` 変更は、
  baseline512 の dispatch 可視性・上位3shape頻度に影響を与えなかった。
- 次の単独ノブ候補:
  - `num_thread`
  - `keep_alive`
  - prompt profile
  - `num_predict`

---

## 27. baseline512 で `num_thread` 単独スイープ（2026-03-24）[main-node confirmed]

### 27.1 目的

- baseline (`num_batch=512`) を固定し、`num_thread` だけを動かして
  上位3shapeヒット数と `rocblas_trace_gemm_lines` の感度を確認。

### 27.2 条件

- `MODEL=gpt-oss:latest`
- `NUM_PREDICT=128`
- `NUM_CTX=8192`
- `NUM_BATCH=512`
- `KEEP_ALIVE=5m`
- `NUM_THREAD={2,4,6,8}`
- `TARGET_SHAPES=512x512x2880,2880x512x4096,4096x512x2880`

実行:

- `MODEL=gpt-oss:latest NUM_PREDICT_LIST=128 NUM_CTX_LIST=8192 NUM_BATCH_LIST=512 NUM_THREAD_LIST=2,4,6,8 TARGET_SHAPES='512x512x2880,2880x512x4096,4096x512x2880' KEEP_ALIVE_LIST=5m RUNS_PER_CASE=1 ./g4-gptoss-anchor-shape-sweep.sh`
- summary:
  - `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260324_040941.txt`
- comparison note:
  - `vega_path_check_logs/g4_baseline512_numthread_sweep_compare_20260324_041230.txt`

### 27.3 結果

- 4ケースすべて `direct_rocblas_or_tensile_dispatch=1`
- 4ケースすべて `rocblas_trace_gemm_lines=1002`
- 4ケースすべて shape ヒット数が同一:
  - `512x512x2880=192`
  - `2880x512x4096=96`
  - `4096x512x2880=96`

### 27.4 判定

- この範囲の `num_thread` 変更は、
  baseline512 の dispatch 可視性・上位3shape頻度に影響を与えなかった。
- 次の単独ノブ候補:
  - prompt profile
  - `num_predict`（より広いレンジ）

---

## 28. baseline512 で prompt profile 単独スイープ（2026-03-24）[main-node confirmed]

### 28.1 目的

- baseline (`num_batch=512`) を固定し、prompt profile だけを動かして
  dispatch 可視性・上位3shapeヒット数の感度を確認。

### 28.2 条件

- `MODEL=gpt-oss:latest`
- `NUM_PREDICT=128`
- `NUM_CTX=8192`
- `NUM_BATCH=512`
- `KEEP_ALIVE=5m`
- `TARGET_SHAPES=512x512x2880,2880x512x4096,4096x512x2880`
- profiles: `short`, `long`, `code`, `math`

実行:

- 4 profile を順次実行（baseline 固定）
  - map: `vega_path_check_logs/g4_baseline512_prompt_profile_map_20260324_042122.tsv`
  - compare: `vega_path_check_logs/g4_baseline512_prompt_profile_sweep_compare_20260324_042420.txt`

### 28.3 結果

- 4 profile すべてで `direct_rocblas_or_tensile_dispatch=1`
- 4 profile すべてで `rocblas_trace_gemm_lines=1002`
- 4 profile すべてで shape ヒット数が同一:
  - `512x512x2880=192`
  - `2880x512x4096=96`
  - `4096x512x2880=96`

### 28.4 判定

- この profile 範囲では prompt 変更は
  baseline512 の dispatch 可視性・上位3shape頻度を動かさなかった。
- 次の単独ノブ候補:
  - `num_predict` の拡張レンジ

---

## 29. baseline512 で `num_predict` 拡張レンジ単独スイープ（2026-03-24）[main-node confirmed]

### 29.1 目的

- baseline (`num_batch=512`) を固定し、`num_predict` を拡張して
  長い decode で dispatch/shape 観測が変化するか確認。

### 29.2 条件

- `MODEL=gpt-oss:latest`
- `NUM_CTX=8192`
- `NUM_BATCH=512`
- `KEEP_ALIVE=5m`
- `NUM_PREDICT={64,128,256,512,1024}`
- `TARGET_SHAPES=512x512x2880,2880x512x4096,4096x512x2880`

実行:

- `MODEL=gpt-oss:latest NUM_PREDICT_LIST=64,128,256,512,1024 NUM_CTX_LIST=8192 NUM_BATCH_LIST=512 TARGET_SHAPES='512x512x2880,2880x512x4096,4096x512x2880' KEEP_ALIVE_LIST=5m RUNS_PER_CASE=1 ./g4-gptoss-anchor-shape-sweep.sh`
- summary:
  - `vega_path_check_logs/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260324_043140.txt`
- comparison notes:
  - `vega_path_check_logs/g4_baseline512_numpredict_sweep_compare_20260324_043625.txt`
  - `vega_path_check_logs/g4_baseline512_numpredict_sweep_table_20260324_043625.tsv`

### 29.3 結果

- 5ケースすべて `direct_rocblas_or_tensile_dispatch=1`
- 5ケースすべて `rocblas_trace_gemm_lines=1002`
- 5ケースすべて shape ヒット数が同一:
  - `512x512x2880=192`
  - `2880x512x4096=96`
  - `4096x512x2880=96`
- `eval_count` は `num_predict` に応じて増加:
  - `64->64`, `128->128`, `256->256`, `512->512`, `1024->797`
  - `1024` は `done_reason=stop` で上限到達前に終了

### 29.4 判定

- 拡張レンジでも baseline512 の「観測された rocBLAS GEMM 署名」は変化しなかった。
- 現在の trace では、観測署名が prefill 優位で固定化されている可能性が高い。
- 次段候補:
  - prefill / decode の観測窓を分離して再計測

---

## 30. prefill/decode 分離（2-pass 差分法）を導入（2026-03-24）[main-node confirmed]

### 30.1 目的

- `baseline512` の固定署名が prefill 起因か、decode でも同署名が継続するかを切り分ける。
- 同一条件で `prefill_proxy` と `full` を連続実行し、`full - prefill_proxy` を decode proxy として比較。

### 30.2 実装

- 追加スクリプト:
  - `g4-prefill-decode-split.sh`
- 実行方式:
  - prefill proxy: `PREFILL_NUM_PREDICT=1`
  - full: `FULL_NUM_PREDICT=128`
  - そのほかは baseline 固定（`gpt-oss`, `num_ctx=8192`, `num_batch=512`, `ROCBLAS_LAYER=9`）
- 生成物:
  - summary: `vega_path_check_logs/g4_prefill_decode_split_gpt-oss_latest_20260324_045227.txt`
  - shape compare: `vega_path_check_logs/g4_prefill_decode_shape_compare_gpt-oss_latest_20260324_045227.tsv`

### 30.3 結果

- prefill proxy / full ともに:
  - `direct=1`
  - `rocblas_trace_gemm_lines=1002`
  - target shape hits `384`（`192/96/96`）
- 差分:
  - `decode_delta_eval_count=127`
  - `decode_delta_gemm_lines=0`
  - `decode_delta_target_shape_hits=0`
  - `phase_split_status=prefill_dominant_signature`

### 30.4 判定

- 現行 anchor で見えている GEMM/shape 署名は prefill 優位である可能性が高い。
- ここでの decode 判定は proxy（`full - prefill_proxy`）であり、厳密な token-level attribution ではない点は保持。

---

## 31. raw ログの既定出力先を `vega_path_check_logs_raw` に統一（2026-03-24）[main-node confirmed]

### 31.1 実施内容

- 既定を外部 raw ディレクトリへ統一:
  - `model-gpu-path-check.sh`
  - `tinyllama-gpu-path-check.sh`
- 集計系の既定入力先を raw 側へ更新:
  - `summarize-fallback-phases.sh`
  - `summarize-fallback-types.sh`
  - `summarize-rocblas-gemm-shapes.sh`
- `README.md` / `README.ja.md` の log policy 記述を更新。

### 31.2 目的

- in-repo (`vega_path_check_logs`) への生ログ滞留を防止。
- 事故要因（巨大差分・broken pipe・一覧過多）を継続的に抑える。

### 31.3 補足

- summary/TSV は引き続き `vega_path_check_logs` に保存。
- raw/probe (`strace`, `rocprof`, `generate json`, `journal`, `rocm-smi`) は `vega_path_check_logs_raw` を既定とする。
