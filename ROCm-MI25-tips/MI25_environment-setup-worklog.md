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

---

## 32. stream=true で TTFT 境界を取得し、phase window を記録（2026-03-24）[main-node confirmed]

### 32.1 目的

- `stream=true` 実行で first-token 境界（TTFT）を明示的に取得する。
- `prefill/decode` の窓分離を、従来の 2-pass 差分に加えて stream 時刻付きで補強する。

### 32.2 実装

- 追加:
  - `g4-stream-phase-window-check.sh`
- 拡張:
  - `g4-fallback-strace-check.sh`（`STREAM=1` 対応、TTFT 計測）
  - `g4-rocprofv3-dispatch-check.sh`（`STREAM=1` 対応、TTFT + phase split proxy）
  - `g4-fallback-dispatch-link-check.sh`（stream/phase 指標を集約）
- 出力項目（抜粋）:
  - `ttft_ms_wall`
  - `stream_total_ms_wall`
  - `stream_first_token_channel`（`response` or `thinking`）
  - `phase_split_status_proxy`
  - `prefill_kernel_tensile_like_rows`
  - `decode_kernel_tensile_like_rows`

### 32.3 実測（gpt-oss anchor, num_predict=64）

- 実行:
  - `NUM_PREDICT=64 ./g4-stream-phase-window-check.sh`
- summary:
  - `vega_path_check_logs/g4_stream_phase_window_gpt-oss_latest_20260324_050710.txt`
- 観測:
  - `ttft_ms_wall_strace=8121.994`
  - `ttft_ms_wall_rocprof=7646.015`
  - `stream_first_token_channel=thinking`（gpt-oss は response 空で thinking を先行出力）
  - `phase_split_status_proxy=decode_signature_detected`
  - `prefill_kernel_tensile_like_rows=0`
  - `decode_kernel_tensile_like_rows=167`

### 32.4 判定

- gpt-oss の stream では first token を `thinking` 側で取る必要があるため、TTFT 判定を response 専用から拡張した。
- phase split は現時点では `kernel_start_min + prompt_eval_duration` による proxy 分割であり、
  厳密な token-level attribution そのものではない点は継続留保とする。

---

## 33. stream phase window を `num_predict=64..1024` で拡張スイープ（2026-03-24）[main-node confirmed]

### 33.1 目的

- 32章で導入した stream window 観測を `num_predict` 拡張レンジで再現し、
  `decode_signature_detected` が長尺でも維持されるか確認する。

### 33.2 実行

- 追加ランナー:
  - `g4-stream-phase-window-sweep.sh`
- 実行コマンド:
  - `NUM_PREDICT_LIST=64,128,256,512,1024 ./g4-stream-phase-window-sweep.sh`
- summary:
  - `vega_path_check_logs/g4_stream_phase_window_sweep_gpt-oss_latest_20260324_105527.txt`
- table:
  - `vega_path_check_logs/g4_stream_phase_window_sweep_gpt-oss_latest_20260324_105527.tsv`

### 33.3 結果

- 5ケースすべて `status=ok`
- 5ケースすべて:
  - `direct_rocblas_or_tensile_dispatch=1`
  - `fallback_confirmed=1`
  - `dispatch_confirmed=1`
  - `phase_split_status_proxy=decode_signature_detected`
  - `prefill_kernel_tensile_like_rows=0`
  - `decode_kernel_tensile_like_rows=167`
  - `stream_first_token_channel=thinking`
- `stream_total_ms_wall` は `num_predict` 増加に伴って増加（64 -> 1024 で大幅増加）。
- TTFT (`ttft_ms_wall`) はおおむね 7.6s-8.5s 帯で推移。

### 33.4 判定

- baseline512 + gpt-oss anchor では、`num_predict=64..1024` の範囲でも
  stream-phase proxy の判定が一貫して `decode_signature_detected` となった。
- これにより、`num_predict` 拡張時の観測窓でも direct-dispatch gate が安定して維持されることを確認。
- ただし本判定は引き続き proxy 分割ベースのため、厳密な token-level attribution は別途課題として残る。

---

## 34. probe/sweep の summary 既定出力先を repo 外へ変更（2026-03-24）[main-node confirmed]

### 34.1 背景

- `vega_path_check_logs/` に未追跡の summary/TSV が継続的に生成され、
  作業差分が肥大化しやすい状態になっていた。

### 34.2 変更

- probe/sweep スクリプトの `LOG_DIR` 既定を次へ統一:
  - `${WORKSPACE_ROOT}/vega_path_check_logs_raw/summaries`
- `RAW_LOG_DIR` は従来通り:
  - `${WORKSPACE_ROOT}/vega_path_check_logs_raw`

対象（例）:

- `g4-fallback-strace-check.sh`
- `g4-rocprofv3-dispatch-check.sh`
- `g4-fallback-dispatch-link-check.sh`
- `g4-stream-phase-window-check.sh`
- `g4-stream-phase-window-sweep.sh`
- `g4-gptoss-anchor-shape-sweep.sh`
- `model-gpu-path-check.sh`
- `tinyllama-gpu-path-check.sh`

### 34.3 運用

- 既定では summary も raw も repo 外に出るため、`git status` のノイズを抑制できる。
- レビュー用に repo 内へ置きたい場合のみ、`LOG_DIR` を明示指定して出力する。

---

## 35. baseline512 vs side1024 の stream phase-window 比較（2026-03-24）[main-node confirmed]

### 35.1 目的

- 既存 baseline512（`num_batch=512`）と side1024（`num_batch=1024`）で、
  stream-phase proxy の安定性と実行時間差を比較する。

### 35.2 実行

- side1024 sweep:
  - `MODEL=gpt-oss:latest NUM_BATCH=1024 NUM_PREDICT_LIST=64,128,256,512,1024 ./g4-stream-phase-window-sweep.sh`
  - summary: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_phase_window_sweep_gpt-oss_latest_20260324_122317.txt`
  - tsv: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_phase_window_sweep_gpt-oss_latest_20260324_122317.tsv`
- baseline vs side compare:
  - compare tsv: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_phase_window_batch_compare_gpt-oss_latest_20260324_123206.tsv`
  - compare txt: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_phase_window_batch_compare_gpt-oss_latest_20260324_123206.txt`

### 35.3 結果

- side1024 の 5ケースすべて `ok`。
- baseline512 / side1024 の両方で 5ケースすべて:
  - `direct_rocblas_or_tensile_dispatch=1`
  - `fallback_confirmed=1`
  - `dispatch_confirmed=1`
  - `phase_split_status_proxy=decode_signature_detected`
  - `decode_kernel_tensile_like_rows=167`
- 差分として、`num_batch=1024` 側は `stream_total_ms_wall_strace` が全ケースで増加:
  - `num_predict=64`: `+5165.371 ms`
  - `128`: `+7400.993 ms`
  - `256`: `+13067.843 ms`
  - `512`: `+25440.684 ms`
  - `1024`: `+40639.563 ms`

### 35.4 判定

- `num_batch` を 512 -> 1024 に上げても、stream-phase proxy の署名そのものは変化しなかった。
- つまり現時点では、batch変更は「可視化署名の種類」より「実行時間スケール」へ強く効いている。
- 観測アンカーとしては baseline512 を正本、side1024 を時間感度比較レーンとして維持する方針が妥当。

---

## 36. keep_alive 単独スイープ（stream phase-window, baseline512）（2026-03-24）[main-node confirmed]

### 36.1 目的

- baseline512 で `keep_alive` のみを動かし、stream-phase proxy の安定性を評価する。
- 特に `dispatch_confirmed` / rocprof CSV 出力可否の感度を確認する。

### 36.2 実装

- 追加ランナー:
  - `g4-stream-keepalive-sweep.sh`
- 既定値（安定運用向け）:
  - `KEEP_ALIVE_LIST=10s,30s,5m`
- 比較テーブル:
  - `timestamp, keep_alive, ttft_ms, total_ms, phase_split_status_proxy, dispatch_confirmed` などを1表に統合。

### 36.3 実測 A（0s,5m,30m）

- 実行:
  - `MODEL=gpt-oss:latest NUM_BATCH=512 NUM_PREDICT_LIST=128 KEEP_ALIVE_LIST=0s,5m,30m ./g4-stream-keepalive-sweep.sh`
- 出力:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_keepalive_sweep_gpt-oss_latest_20260324_123600.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_keepalive_sweep_gpt-oss_latest_20260324_123600.tsv`
- 結果:
  - `keep_alive=0s`: `dispatch_confirmed=0`, `phase_split_status_proxy=unavailable`, `decode_rows=0`
  - `keep_alive=5m`: `dispatch_confirmed=1`, `phase_split_status_proxy=decode_signature_detected`, `decode_rows=167`
  - `keep_alive=30m`: `dispatch_confirmed=1`, `phase_split_status_proxy=decode_signature_detected`, `decode_rows=167`

### 36.4 実測 B（0s 再現確認）

- 実行:
  - 0s 条件を2回再試行
- 出力:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_keepalive_0s_recheck_20260324_123825.tsv`
- 結果（2/2一致）:
  - `dispatch_confirmed=0`
  - `phase_split_status_proxy=unavailable`
  - `trace_file_count=0`, `csv_file_count=0`

### 36.5 実測 C（1s,10s,30s,5m）

- 実行:
  - `MODEL=gpt-oss:latest NUM_BATCH=512 NUM_PREDICT_LIST=128 KEEP_ALIVE_LIST=1s,10s,30s,5m ./g4-stream-keepalive-sweep.sh`
- 出力:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_keepalive_sweep_gpt-oss_latest_20260324_123938.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_keepalive_sweep_gpt-oss_latest_20260324_123938.tsv`
- 結果:
  - `1s`: `dispatch_confirmed=0`, `phase=unavailable`, `decode_rows=0`
  - `10s/30s/5m`: すべて `dispatch_confirmed=1`, `phase=decode_signature_detected`, `decode_rows=167`

### 36.6 判定

- stream+rocprof 観測で `keep_alive` が短すぎると（今回の観測では `0s` と `1s`）、
  rocprof CSV が空になり phase proxy が `unavailable` になる再現性がある。
- `keep_alive>=10s` では、dispatch/phase 観測が安定して成立した。
- よって、観測運用の推奨下限を `keep_alive>=10s` に設定する。

---

## 37. keep_alive 閾値の side1024 再検証（2026-03-24）[main-node confirmed]

### 37.1 目的

- 36章で得た `keep_alive>=10s` の閾値が、side1024（`num_batch=1024`）でも成立するか確認。

### 37.2 実行

- 実行:
  - `MODEL=gpt-oss:latest NUM_BATCH=1024 NUM_PREDICT_LIST=128 KEEP_ALIVE_LIST=1s,10s,30s ./g4-stream-keepalive-sweep.sh`
- 出力:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_keepalive_sweep_gpt-oss_latest_20260324_124412.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_keepalive_sweep_gpt-oss_latest_20260324_124412.tsv`
- batch横断比較:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_keepalive_batch_compare_gpt-oss_latest_20260324_124713.tsv`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_keepalive_batch_compare_gpt-oss_latest_20260324_124713.txt`

### 37.3 結果

- `num_batch=1024` でも:
  - `keep_alive=1s` は `dispatch_confirmed=0`, `phase=unavailable`, `decode_rows=0`
  - `keep_alive=10s/30s` は `dispatch_confirmed=1`, `phase=decode_signature_detected`, `decode_rows=167`
- baseline512 と side1024 の両レーンで、閾値パターンが一致:
  - `1s` は不安定（rocprof CSV が空）
  - `10s+` は安定観測

### 37.4 判定

- `keep_alive>=10s` の推奨下限は、baseline512 だけでなく side1024 でも再現した。
- 以後の stream-phase 観測では、再現性確保のため `keep_alive=10s` 以上を既定運用にする。

---

## 38. anchor lane status 自動集約を追加（2026-03-25）[main-node confirmed]

### 38.1 目的

- baseline512 / side1024 の固定観測結果を、毎回同じ形で要約する。
- stream phase-window の gate 一貫性（direct/fallback/dispatch + decode_signature）を
  1ファイルで確認できるようにする。

### 38.2 実装

- 追加スクリプト:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/summarize-g4-anchor-lanes.sh`
- 入力:
  - baseline anchor summary (`num_batch_list=512` の gpt-oss anchor 集約)
  - side anchor summary (`num_batch_list=1024` の gpt-oss anchor 集約)
  - stream phase-window batch compare TSV
- 出力:
  - `g4_anchor_lane_status_gpt-oss_latest_<ts>.txt`
  - `g4_anchor_lane_status_gpt-oss_latest_<ts>.tsv`
  - 保存先: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/`

### 38.3 実行結果

- 実行:
  - `./summarize-g4-anchor-lanes.sh`
- 出力:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_anchor_lane_status_gpt-oss_latest_20260325_010009.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_anchor_lane_status_gpt-oss_latest_20260325_010009.tsv`
- 要約（抜粋）:
  - baseline lane: `ok_cases=5`, `direct_hits=5`, shape totals `(960,480,480)`
  - side lane: `ok_cases=3`, `direct_hits=3`, shape totals `(864,432,432)`
  - stream compare: `rows=5`, `all_direct_gate_rows=5`, `all_decode_signature_rows=5`

### 38.4 判定

- baseline / side 両レーンで direct dispatch の安定性を再確認。
- stream phase-window の decode 側署名が batch比較でも一貫していることを再確認。
- 観測系の「固定比較フロー」は、手動確認からスクリプト再現へ移行できた。

---

## 39. non-dot4 候補整理用の dtype 集約を追加（2026-03-25）[main-node confirmed]

### 39.1 目的

- 週次残務のうち
  - `non-dot4 側の本命候補を整理`
  - `どの shape から先に刺すかを優先付け`
  を、再実行可能な形で確定する。

### 39.2 実装

- 追加スクリプト:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/summarize-rocblas-gemm-dtypes.sh`
- 入力:
  - `rocblas_gemm_shapes_*.tsv`（既存 shape 集約結果）
- 出力:
  - `rocblas_gemm_dtype_summary_<...>.txt/.tsv`
  - 保存先: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/`

### 39.3 実行

- コマンド:
  - `./summarize-rocblas-gemm-dtypes.sh /home/limonene/ROCm-project/vega_path_check_logs_raw/rocblas_gemm_shapes_g4_rocblas_trace_gpt-oss_latest_20260324_045255_20260324_045658.tsv`
- 出力:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/rocblas_gemm_dtype_summary_rocblas_gemm_shapes_g4_rocblas_trace_gpt-oss_latest_20260324_045255_20260324_045658_20260325_010632.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/rocblas_gemm_dtype_summary_rocblas_gemm_shapes_g4_rocblas_trace_gpt-oss_latest_20260324_045255_20260324_045658_20260325_010632.tsv`

### 39.4 結果

- `total_gemm=501`
- `non_dot4_like=501`（100%）
- `int8_or_i32_like=0`
- dtype内訳:
  - `bf16_r|bf16_r|||` = `288`（57.49%）
  - `f16_r|f16_r|||` = `144`（28.74%）
  - `f32_r|f32_r|f32_r|f32_r|f32_r` = `69`（13.77%）
- 上位shape:
  - `512x512x2880`（96）
  - `2880x512x4096`（48）
  - `4096x512x2880`（48）
  - `512x93x2880`（48）
  - `32x512x2880`（46）

### 39.5 判定

- 現行 anchor 条件では、dispatch 可視化された GEMM は non-dot4 系が主（この測定では 100%）。
- 低レイヤーの次ステップは、`Tier-1: 512x512x2880 / 2880x512x4096 / 4096x512x2880` から着手する。
- int8 系は、現時点では「catalog-read で見えるが direct dispatch で未確認」の扱いを維持する。

---

## 40. raw ログ退避スクリプトの出力先を repo 外に固定（2026-03-25）[main-node confirmed]

### 40.1 背景

- `migrate-raw-logs.sh` の既定 `SUMMARY_DIR` が repo 内
  (`ROCm-MI25-build/vega_path_check_logs`) を向いており、
  実行すると summary/manifest が repo 内に増える余地が残っていた。

### 40.2 変更

- 対象:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/migrate-raw-logs.sh`
- 変更点:
  - `SUMMARY_DIR` の既定を
    - 旧: `$SCRIPT_DIR/vega_path_check_logs`
    - 新: `$DST_DIR/summaries`（= `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries`）
  - `SRC_DIR` が存在しない場合は no-op で終了し、`summary=none` を返すようにした
    （空ディレクトリを勝手に生成しない）。

### 40.3 簡易確認

- 構文チェック:
  - `bash -n migrate-raw-logs.sh` -> `ok`
- no-op 動作確認:
  - `SRC_DIR=/tmp/rocm_no_such_dir_for_test ./migrate-raw-logs.sh`
  - 出力: `summary=none`, `manifest=none`, `note=src_dir_not_found:...`

### 40.4 判定

- 退避運用で summary/manifest が repo 内へ逆流しにくくなった。
- 今後は raw/summary を `vega_path_check_logs_raw` 側で完結させる運用を継続できる。

---

## 41. Tier-1 shape 観測メモを分割（2026-03-25）[main-node confirmed]

### 41.1 目的

- TODO「上位 shape ごとに観測メモを分ける」に対応し、
  Queue-A (`512x512x2880`, `2880x512x4096`, `4096x512x2880`) を個別管理にする。

### 41.2 追加証跡（同日再計測）

- baseline512 prefill/decode split:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_011553.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_shape_compare_gpt-oss_latest_20260325_011553.tsv`
- side1024 prefill/decode split:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_011411.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_shape_compare_gpt-oss_latest_20260325_011411.tsv`

### 41.3 要点

- baseline512 / side1024 の両方で:
  - `direct=1`, `fallback=1`, `dispatch=1`
  - `kernel_tensile_like_rows=167`
  - `phase_split_status=prefill_dominant_signature`
- Queue-A 3shapeの decode proxy は全て `decode_delta=0`（現行 proxy 分離では差分未検出）。

### 41.4 メモ分割先

- `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/README.md`
- `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_512x512x2880.md`
- `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_2880x512x4096.md`
- `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_4096x512x2880.md`

### 41.5 判定

- Queue-A の「shapeごと比較（dispatch/gemm/Tensile/prefill-decode）」は分割済み。
- Queue-B/C も分割済み（Section 43 参照）。

---

## 42. 全shape prefill/full 比較テーブルを追加（2026-03-25）[main-node confirmed]

### 42.1 目的

- Queue-A だけでなく Queue-B/C も同じ基準で観測できるよう、
  `rocblas_trace` 2本（prefill/full）から全shape差分を自動比較する。

### 42.2 実装

- 追加スクリプト:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/compare-rocblas-shape-counts.sh`
- 入力:
  - prefill/fill 各 `g4_rocblas_trace_*.log`
- 出力:
  - `rocblas_shape_prefill_full_compare_<prefill>__<full>_<ts>.txt/.tsv`
  - 保存先: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/`

### 42.3 実行と結果

- baseline512:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/rocblas_shape_prefill_full_compare_g4_rocblas_trace_gpt-oss_latest_20260325_011553__g4_rocblas_trace_gpt-oss_latest_20260325_011629_20260325_012104.tsv`
  - `__TOTAL__`: `501 -> 501`, `delta=0`
- side1024:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/rocblas_shape_prefill_full_compare_g4_rocblas_trace_gpt-oss_latest_20260325_011411__g4_rocblas_trace_gpt-oss_latest_20260325_011439_20260325_012104.tsv`
  - `__TOTAL__`: `668 -> 668`, `delta=0`

Queue-B/C 可視化（抜粋）:

- baseline:
  - `512x93x2880=48`, `32x512x2880=46`
  - `4608x512x64`, `64x512x4608`, `8192x512x64`, `64x512x8192` は各 `24`
- side:
  - `32x1024x2880=69`
  - `5120x1024x64`, `64x1024x5120`, `8192x1024x64`, `64x1024x8192` は各 `36`

### 42.4 判定

- Queue-B/C も含めた全shapeが prefill/full 比較テーブルで参照可能になった。
- 現行 anchor では、全体として `prefill_count == full_count`（proxy 差分 0）が継続。

---

## 43. Queue-B/C の shape個別メモを追加（2026-03-25）[main-node confirmed]

### 43.1 目的

- Queue-A に続き、Queue-B/C も shape単位で比較メモを揃える。
- TODO の「shapeごと比較（dispatch/gemm/Tensile/prefill-decode）」を
  Queue-A/B/C 全体で同一粒度にする。

### 43.2 追加

- index:
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/README.md`
- Queue-B:
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_512x93x2880.md`
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_32x512x2880.md`
- Queue-C:
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_4608x512x64.md`
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_64x512x4608.md`
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_8192x512x64.md`
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_64x512x8192.md`

### 43.3 比較基準

- 参照 split:
  - baseline: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_011553.txt`
  - side: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_011411.txt`
- 全shape compare:
  - baseline: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/rocblas_shape_prefill_full_compare_g4_rocblas_trace_gpt-oss_latest_20260325_011553__g4_rocblas_trace_gpt-oss_latest_20260325_011629_20260325_012104.tsv`
  - side: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/rocblas_shape_prefill_full_compare_g4_rocblas_trace_gpt-oss_latest_20260325_011411__g4_rocblas_trace_gpt-oss_latest_20260325_011439_20260325_012104.tsv`

### 43.4 判定

- Queue-A/B/C で shape個別メモ化を完了。
- 以後は「効果が見えた shape から低レイヤーへ刺す」フェーズへ移行可能。

---

## 44. kernel 候補の自動抽出を追加（2026-03-25）[main-node confirmed]

### 44.1 目的

- TODO「上位 shape に対応する kernel 候補を絞る」に対応し、
  rocprof prefill/full 2本から kernel 候補を同一形式で抽出する。

### 44.2 実装

- 追加スクリプト:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/summarize-kernel-candidates.sh`
- 入力:
  - prefill/full の `rocprofv3_summary_*.txt`（`kernel_trace_file` を内部参照）
- 出力:
  - `kernel_candidates_<prefill>__<full>_<ts>.txt/.tsv`
  - 保存先: `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/`

### 44.3 実行結果（baseline/side）

- baseline (`num_batch=512`):
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_011606__rocprofv3_summary_gpt-oss_latest_20260325_011645_20260325_013150.tsv`
  - dispatch rows: `2384 -> 25204` (`delta=22820`)
- side (`num_batch=1024`):
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_011425__rocprofv3_summary_gpt-oss_latest_20260325_011502_20260325_013150.tsv`
  - dispatch rows: `2383 -> 25021` (`delta=22638`)

両laneで上位に出る候補（抜粋）:

- `mul_mat_vec_f<__hip_bfloat16, float, ...>`
- `mul_mat_vec_q<(ggml_type)39, ...>`
- `mul_mat_q<(ggml_type)39, ...>`
- `Cijk_*` 系（Tensile kernel name）

### 44.4 判定

- 「上位 shape に対応する kernel 候補を絞る」は最低限の自動化と証跡整理まで完了。
- 次段は `Cijk_*` を起点に HSACO 抽出と逆アセンブル対象の最小化へ進む。

---

## 45. HSACO 対応付けと抽出（2026-03-25）[main-node confirmed]

### 45.1 目的

- `Cijk_*` 候補を実ファイルへ対応付けし、逆アセンブル対象を最小化する。

### 45.2 実装

- 対応付けスクリプト:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/map-kernel-candidates-to-hsaco.sh`
- 抽出スクリプト:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/extract-hsaco-targets.sh`

### 45.3 対応付け結果

- baseline map:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_011606__rocprofv3_summary_gpt-oss_latest_20260325_011645_20260325_013150_20260325_013452.tsv`
- side map:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_011425__rocprofv3_summary_gpt-oss_latest_20260325_011502_20260325_013150_20260325_013439.tsv`

一致状況:

- `Cijk_*` 4候補のうち 3候補が `*_fallback_gfx900.hsaco` と1:1で一致。
- 1候補（`...ISA900...`）は現行 `*gfx900*.hsaco` では未一致。

### 45.4 抽出結果

- manifest:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/hsaco_targets_hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_011606__rocprofv3_summary_gpt-oss_latest_20260325_011645_20260325_013150_20260325_013452_20260325_013541.txt`
- extracted dir:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/hsaco_targets_hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_011606__rocprofv3_summary_gpt-oss_latest_20260325_011645_20260325_013150_20260325_013452_20260325_013541`

抽出3件（合計 876KB）:

- `TensileLibrary_Type_BB_HPA_Contraction_l_Alik_Bljk_Cijk_Dijk_fallback_gfx900.hsaco`
- `TensileLibrary_Type_HH_Contraction_l_Alik_Bljk_Cijk_Dijk_fallback_gfx900.hsaco`
- `TensileLibrary_Type_HS_HPA_Contraction_l_Alik_Bljk_Cijk_Dijk_fallback_gfx900.hsaco`

### 45.5 判定

- TODO の「対象 HSACO を抜き出す」「逆アセンブル対象を最小限にする」に対応完了。
- 次段はこの3件を対象に命令列観察（dot4/packed/memory傾向）へ進む。

---

## 46. 抽出HSACOの逆アセンブル信号集計（2026-03-25）[main-node confirmed]

### 46.1 実装

- 追加スクリプト:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/summarize-hsaco-disasm-signals.sh`
- 入力:
  - Section 45で抽出した 3HSACO ディレクトリ
- 出力:
  - signal summary:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/disasm_signal_summary_hsaco_targets_hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_011606__rocprofv3_summary_gpt-oss_latest_20260325_011645_20260325_013150_20260325_013452_20260325_013541_20260325_013821.txt`
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/disasm_signal_summary_hsaco_targets_hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_011606__rocprofv3_summary_gpt-oss_latest_20260325_011645_20260325_013150_20260325_013452_20260325_013541_20260325_013821.tsv`
  - disasm files:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/disasm_hsaco_targets_hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_011606__rocprofv3_summary_gpt-oss_latest_20260325_011645_20260325_013150_20260325_013452_20260325_013541_20260325_013821/`

### 46.2 確認済み（facts）

- `total_files=3`
- `dot4_positive_files=0`
- `packed_positive_files=1`
- `mfma_positive_files=0`
- `memory_positive_files=3`

per-file（抜粋）:

- `Type_BB_HPA ... fallback_gfx900.hsaco`
  - `dot4=0`, `packed=0`, `mfma=0`, `fma/mac/mad=8372`, `memory=5429`
- `Type_HH ... fallback_gfx900.hsaco`
  - `dot4=0`, `packed=720`, `mfma=0`, `fma/mac/mad=500`, `memory=893`
- `Type_HS_HPA ... fallback_gfx900.hsaco`
  - `dot4=0`, `packed=0`, `mfma=0`, `fma/mac/mad=5770`, `memory=3393`

### 46.3 確認済みの命令例（facts）

- packed系（HH fallback）:
  - `v_pk_fma_f16 ...`
- memory系:
  - `global_load_dword ...`
  - `ds_read2_b32 ...`
  - `ds_write_b16 ...`

### 46.4 推測（inference）

- 現行3対象では、dot4/mfmaよりも FMA系 + LDS/Global メモリアクセス中心の
  署名が優勢。
- `Type_HH` fallback に packed (`v_pk_fma_f16`) が集中しており、
  次の詳細読解はこのファイル優先が効率的。

---

## 47. 観測深掘りサイクル（改造なし）(2026-03-25 02:23 JST) [main-node confirmed]

意図:

- 「深く見る」をコード改造ではなく観測粒度向上として実施。
- 対象は以下のみ:
  - top shape 再観測
  - baseline/side 安定性確認
  - prefill/full proxy と stream window の比較
  - candidate/hsaco/note 反映更新

### 47.1 top shape 再観測（anchor lane）

- baseline (`num_batch=512`):
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260325_022355.txt`
  - `shape_512x512x2880=192`
  - `shape_2880x512x4096=96`
  - `shape_4096x512x2880=96`
  - `direct/fallback/dispatch=1`, `gemm_lines=1002`
- side (`num_batch=1024`):
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260325_022435.txt`
  - `shape_512x1024x2880=288`
  - `shape_2880x1024x4096=144`
  - `shape_4096x1024x2880=144`
  - `direct/fallback/dispatch=1`, `gemm_lines=1336`

### 47.2 prefill/full proxy 比較

- baseline split:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_022531.txt`
- side split:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_022637.txt`
- 両lane共通:
  - `decode_delta_gemm_lines=0`
  - `decode_delta_target_shape_hits=0`
  - `phase_split_status=prefill_dominant_signature`

### 47.3 stream phase-window 比較（prefill/decode 別レイヤ）

- baseline:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_phase_window_sweep_gpt-oss_latest_20260325_022802.txt`
- side:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_phase_window_sweep_gpt-oss_latest_20260325_022953.txt`
- 両lane共通:
  - `ok_cases=3`
  - `decode_signature_cases=3`
  - 全行 `direct/fallback/dispatch=1`
  - `decode_kernel_tensile_like_rows=167`

### 47.4 candidate -> hsaco 更新

- kernel candidates:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_022545__rocprofv3_summary_gpt-oss_latest_20260325_022614_20260325_023311.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_022651__rocprofv3_summary_gpt-oss_latest_20260325_022727_20260325_023315.txt`
- hsaco map:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_022545__rocprofv3_summary_gpt-oss_latest_20260325_022614_20260325_023311_20260325_023331.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_022651__rocprofv3_summary_gpt-oss_latest_20260325_022727_20260325_023315_20260325_023336.txt`
- map 結果（両lane同じ）:
  - `total_candidates=4`
  - `matched_candidates=3`
  - unmatched `...ISA900...` 1件は継続
- extract/disasm:
  - extract manifest:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/hsaco_targets_hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_022545__rocprofv3_summary_gpt-oss_latest_20260325_022614_20260325_023311_20260325_023331_20260325_023347.txt`
  - disasm summary:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/disasm_signal_summary_hsaco_targets_hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_022545__rocprofv3_summary_gpt-oss_latest_20260325_022614_20260325_023311_20260325_023331_20260325_023347_20260325_023354.txt`
  - signal:
    - `dot4_positive_files=0`
    - `mfma_positive_files=0`
    - `packed_positive_files=1`
    - `memory_positive_files=3`

### 47.5 判定

- このサイクルは「観測・比較・記録」の深掘りとして完了。
- 低レイヤ改造は未着手のまま維持し、次段は shape 優先で証拠粒度をさらに上げる。

---

## 48. Tier-1 shape別 kernel-priority memo 作成（2026-03-25）[main-node confirmed]

目的:

- 「本命shapeを1個ずつ深く見る」を、改造なしで文書化しやすい単位に固定する。

追加ファイル:

- `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_512x512x2880_kernel_priority.md`
- `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_2880x512x4096_kernel_priority.md`
- `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_4096x512x2880_kernel_priority.md`

内容:

- shape別 baseline/side 安定性
- stream-window decode 署名
- lane-level `Cijk_*` 候補優先順
- HSACO map (`3 matched + 1 unmatched`) との対応
- Mermaid による `shape -> candidate -> hsaco` 可視化

判定:

- ここまでの作業は観測・比較・記録のみで、低レイヤ改造は未実施。

---

## 49. Queue-B/C shape別 kernel-priority memo 追加（2026-03-25）[main-node confirmed]

目的:

- Tier-1 で作成した shape別 memo 形式を Queue-B/C に展開し、
  「本命shape以外の候補列」も同じ粒度で比較可能にする。

追加ファイル:

- Queue-B:
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_512x93x2880_kernel_priority.md`
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_32x512x2880_kernel_priority.md`
- Queue-C:
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_4608x512x64_kernel_priority.md`
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_64x512x4608_kernel_priority.md`
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_8192x512x64_kernel_priority.md`
  - `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_64x512x8192_kernel_priority.md`

共通構成:

- baseline/side shape観測値
- stream-window decode署名
- lane-level `Cijk_*` 優先順
- HSACO対応（`3 matched + 1 unmatched`）
- Mermaid 可視化（`shape -> candidate -> hsaco`）

判定:

- Queue-B/C も観測-onlyテンプレートで揃った。
- 低レイヤ改造は未着手のまま維持。

---

## 50. 全9shapeの優先順位サマリ1枚化（2026-03-25）[main-node confirmed]

目的:

- Tier-1 + Queue-B/C を1枚で俯瞰できる導線を用意する。

追加:

- `/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/shape-observations/shape_priority_overview.md`

内容:

- queue map（Tier-1 / Queue-B / Queue-C）
- baseline/side 観測カウント表
- shared candidate/hsaco layer（`K1..K4`, `3 matched + 1 unmatched`）
- Mermaid 可視化

判定:

- 「どこから刺すか」の見通しが、単一ファイルで追える状態になった。
- ここまでの作業は引き続き観測・比較・記録のみ。

---

## 51. decode署名の再現性固定（baseline/side再走）(2026-03-25 03:31-03:33 JST) [main-node confirmed]

意図:

- 「深く見る」を改造ではなく観測再現で進める。
- `gpt-oss` anchor で baseline/side の decode 側署名を再確認する。

固定条件:

- `MODEL=gpt-oss:latest`
- `ROCBLAS_LAYER=9`
- baseline lane: `NUM_BATCH=512`
- side lane: `NUM_BATCH=1024`

実行コマンド:

```bash
cd /home/limonene/ROCm-project/ROCm-MI25-build
MODEL=gpt-oss:latest NUM_BATCH=512 ROCBLAS_LAYER=9 ./g4-stream-phase-window-sweep.sh
MODEL=gpt-oss:latest NUM_BATCH=1024 ROCBLAS_LAYER=9 ./g4-stream-phase-window-sweep.sh
MODEL=gpt-oss:latest NUM_BATCH=512 ROCBLAS_LAYER=9 ./g4-prefill-decode-split.sh
MODEL=gpt-oss:latest NUM_BATCH=1024 ROCBLAS_LAYER=9 ./g4-prefill-decode-split.sh
```

証跡（summary）:

- phase-window sweep
  - baseline:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_phase_window_sweep_gpt-oss_latest_20260325_031811.txt`
  - side:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_phase_window_sweep_gpt-oss_latest_20260325_032242.txt`
- prefill/full split
  - baseline:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_032955.txt`
  - side:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_033100.txt`

確認結果（facts）:

- phase-window（num_predict `64,128,256,512,1024`）
  - baseline: `ok_cases=5`, `decode_signature_cases=5`
  - side: `ok_cases=5`, `decode_signature_cases=5`
  - 両lane共通:
    - `direct_rocblas_or_tensile_dispatch=1`
    - `fallback_confirmed=1`
    - `dispatch_confirmed=1`
    - `decode_kernel_tensile_like_rows=167`
- prefill/full split（prefill=1, full=128）
  - 両lane共通:
    - `phase_split_status=prefill_dominant_signature`
    - `decode_delta_gemm_lines=0`
    - `decode_delta_target_shape_hits=0`

補足（facts）:

- side split は baseline-target shape
  (`512x512x2880`, `2880x512x4096`, `4096x512x2880`) を使っているため、
  `shape_hits=0` になりやすい。
- side lane で shape delta を追う場合は `*x1024x*` 系 target set を別途使うのが妥当。

補正再走（facts）:

- side lane (`NUM_BATCH=1024`) で `TARGET_SHAPES` を `*x1024x*` 系に補正して再実行:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_033458.txt`
- 確認値:
  - `shape_512_1024_2880=288`
  - `shape_2880_1024_4096=144`
  - `shape_4096_1024_2880=144`
- 補正後も `phase_split_status=prefill_dominant_signature` は維持。

推測（inference）:

- decode署名の再現性は stream-window レイヤでは固定できた。
- prefill/full proxy と stream-window は別レイヤ証拠として扱う必要がある
  （同一ゲートとして混同しない）。

判定:

- 今回サイクルは「観測・比較・記録」の深掘りとして完了。
- 低レイヤ改造は未着手のまま維持。

---

## 52. Step3 最小UX: anchor観測ラベル表示の追加（2026-03-25）[main-node confirmed]

目的:

- 研究結論の実装ではなく、現在の再現事実を安全に見せる最小UXを追加する。
- 原因断定を避け、観測ラベルのみを返す。

追加:

- 新規スクリプト:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/g4-anchor-observation-status.sh`

仕様（断定回避）:

- 出力ラベル:
  - `decode_signature_label=...`
  - `fallback_label=...`
  - `dispatch_label=...`
  - `shape_match_note=...`
- 安全ガード:
  - `anchor_scope_note=anchor_condition_limited_to_current_probe`
  - `anchor_scope_match=0|1`
  - `kernel_mapping_note=...pending...`
  - `generalization_note=do_not_generalize_to_other_workloads_without_revalidation`

実行確認:

```bash
cd /home/limonene/ROCm-project/ROCm-MI25-build
./g4-anchor-observation-status.sh
LANE=side ./g4-anchor-observation-status.sh
```

証跡:

- baseline:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_anchor_observation_status_gpt-oss_latest_20260325_085744.txt`
- side:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_anchor_observation_status_gpt-oss_latest_20260325_085825.txt`

確認値（facts）:

- baseline:
  - `decode_signature_label=decode_signature_observed`
  - `fallback_label=fallback_confirmed`
  - `dispatch_label=dispatch_confirmed`
  - `shape_match_note=shape_match_observed` (`shape_hit_total=384`)
- side:
  - `decode_signature_label=decode_signature_observed`
  - `fallback_label=fallback_confirmed`
  - `dispatch_label=dispatch_confirmed`
  - `shape_match_note=shape_match_observed` (`shape_hit_total=576`)

判定:

- 「勝利宣言UI」ではなく、「観測結果を安全に返す最小UX」として成立。
- kernel-level の厳密因果は pending 表示で維持（過剰一般化を回避）。

---

## 53. Step3 文書反映（safe UX minimum の EN/JA 追加）(2026-03-25) [main-node confirmed]

目的:

- Step3 を「研究結論の実装」ではなく、現在の再現事実を安全に見せる最小UX文書として定着させる。
- 断定を避けた運用ガイドを EN/JA で揃える。

追加/更新:

- 追加:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/ROCm-MI25-tips/MI25_ollama_ux_minimum.md`
  - `/home/limonene/ROCm-project/ROCm-MI25-build/ROCm-MI25-tips/MI25_ollama_ux_minimum.ja.md`
- 更新:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/README.md`
  - `/home/limonene/ROCm-project/ROCm-MI25-build/README.ja.md`

文書化した内容（facts）:

- anchor 条件限定の観測ラベル表示（decode/fallback/dispatch/shape）
- `keep_alive>=10s`（実運用既定 `5m`）を含む safe 条件
- `ollama run` 向け最小設定（`num_ctx=8192`, `num_batch=512`, side=1024）
- upstream 還元候補（観測ステータス表示、anchor_scope、short keep_alive 警告 等）
- `catalog-read` と `dispatch` を別レイヤとして扱う注意

判定:

- 「安全な最小UXとしての見せ方」は EN/JA で一貫化できた。
- kernel-level 因果は未確定として明示し、過剰一般化を回避できている。

---

## 54. 観測→比較→記録サイクル（shape最優先・改造なし）(2026-03-25 09 JST) [main-node confirmed]

目的:

- 「まず観測・比較・記録、それから最適化」の順を維持する。
- 低レイヤ改造を入れず、Tier-1 形状の再現性を更新する。

実行（固定条件）:

- `MODEL=gpt-oss:latest`
- `NUM_CTX=8192`
- `ROCBLAS_LAYER=9`
- `KEEP_ALIVE=5m`
- lane:
  - baseline: `NUM_BATCH=512`
  - side: `NUM_BATCH=1024`

観測（facts）:

- anchor shape sweep:
  - baseline:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260325_090936.txt`
    - `direct_hits=1`, `shape=(192,96,96)`
  - side:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_gptoss_anchor_shape_sweep_gpt-oss_latest_20260325_091016.txt`
    - `direct_hits=1`, `shape=(288,144,144)`
- stream phase-window sweep:
  - baseline:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_phase_window_sweep_gpt-oss_latest_20260325_091108.txt`
    - `ok_cases=5`, `decode_signature_cases=5`
  - side:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_stream_phase_window_sweep_gpt-oss_latest_20260325_091604.txt`
    - `ok_cases=5`, `decode_signature_cases=5`
- prefill/full split:
  - baseline:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_092315.txt`
    - `phase_split_status=prefill_dominant_signature`, `decode_delta_gemm_lines=0`, `decode_delta_target_shape_hits=0`
  - side:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_092419.txt`
    - `phase_split_status=prefill_dominant_signature`, `decode_delta_gemm_lines=0`, `decode_delta_target_shape_hits=0`

比較（facts）:

- lane統合サマリを生成:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_anchor_lane_status_gpt-oss_latest_20260325_092620.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_anchor_lane_status_gpt-oss_latest_20260325_092620.tsv`
- 集計結果:
  - baseline: `anchor_ok=1`, `direct_hits=1`, `stream_decode_signature_cases=5/5`
  - side: `anchor_ok=1`, `direct_hits=1`, `stream_decode_signature_cases=5/5`
  - split は両laneとも `prefill_dominant_signature`（proxy層）

判定:

- 本サイクルは「観測→比較→記録」の更新として完了。
- 低レイヤ改造は未着手のまま維持。

---

## 55. 低レイヤ最適化の入口着手（shape=512x512x2880 ペア）(2026-03-25 10 JST) [main-node confirmed]

目的:

- 低レイヤ改造を急がず、まず「最初に刺す対象」を固定する。
- Tier-1 最優先 shape（baseline/side ペア）を入口にする。

対象:

- baseline: `512x512x2880`
- side: `512x1024x2880`

実施（facts）:

- baseline split 由来の kernel candidate 抽出:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_092328__rocprofv3_summary_gpt-oss_latest_20260325_092357_20260325_105550.txt`
- side split 由来の kernel candidate 抽出:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_092433__rocprofv3_summary_gpt-oss_latest_20260325_092510_20260325_105556.txt`
- candidate -> hsaco 再マップ（baseline/side）:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_092328__rocprofv3_summary_gpt-oss_latest_20260325_092357_20260325_105550_20260325_105606.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_092433__rocprofv3_summary_gpt-oss_latest_20260325_092510_20260325_105556_20260325_105606.txt`

確認結果（facts）:

- baseline/side とも同じ結果:
  - `total_candidates=4`
  - `matched_candidates=3`
  - unmatched は `..._SB_..._ISA900...` 1件
- 既存の `K1/K2/K3 matched + K4 unmatched` 構造が再確認された。

判定:

- 「低レイヤ最適化を始める」の入口条件は満たした。
- ここでの着手は、対象固定と証跡更新まで（コード改変は未実施）。

---

## 56. K1入口の lane一括集計スクリプト追加（2026-03-25 11 JST）[main-node confirmed]

目的:

- 「観測→比較→記録」の繰り返しを手動手順から定型化する。
- baseline/side を同じ手順で再評価し、K1..K4 の入口状態を1表で確認する。

追加:

- `/home/limonene/ROCm-project/ROCm-MI25-build/summarize-k1-entry.sh`

処理内容:

- input:
  - baseline split summary
  - side split summary
- flow:
  - `summarize-kernel-candidates.sh`
  - `map-kernel-candidates-to-hsaco.sh`
  - laneごとの `K1..K4` prefill/full/delta/match を統合TSVへ出力

実行:

```bash
cd /home/limonene/ROCm-project/ROCm-MI25-build
./summarize-k1-entry.sh \
  /home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_092315.txt \
  /home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_prefill_decode_split_gpt-oss_latest_20260325_092419.txt
```

証跡:

- summary:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/k1_entry_lane_check_20260325_110634.txt`
- tsv:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/k1_entry_lane_check_20260325_110634.tsv`

確認結果（facts）:

- baseline/side 共通:
  - `total_candidates=4`
  - `matched_candidates=3`
  - `K1_full=96`, `K1_match=1`
  - `K4_match=0`

判定:

- K1入口の再確認を、毎回同一フォーマットで更新できる状態になった。
- 低レイヤ改造に入る前の gate-check 自動化として有効。

---

## 57. K1入口の HSACO/disasm 再確認（baseline/side 同値）(2026-03-25 11 JST) [main-node confirmed]

目的:

- K1入口の lane 比較を candidate/map だけでなく、HSACO 逆アセンブル信号まで揃えて確認する。

実施:

- HSACO 抽出（baseline/side map それぞれ）:
  - `extract-hsaco-targets.sh`
- 逆アセンブル信号集計（baseline/side それぞれ）:
  - `summarize-hsaco-disasm-signals.sh`

証跡:

- baseline disasm summary:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/disasm_signal_summary_hsaco_targets_hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_092328__rocprofv3_summary_gpt-oss_latest_20260325_092357_20260325_110634_20260325_110635_20260325_110812_20260325_110821.txt`
- side disasm summary:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/disasm_signal_summary_hsaco_targets_hsaco_candidate_map_kernel_candidates_rocprofv3_summary_gpt-oss_latest_20260325_092433__rocprofv3_summary_gpt-oss_latest_20260325_092510_20260325_110636_20260325_110636_20260325_110812_20260325_110822.txt`

確認結果（facts）:

- baseline/side とも同一:
  - `total_files=3`
  - `dot4_positive_files=0`
  - `mfma_positive_files=0`
  - `packed_positive_files=1`
  - `memory_positive_files=3`
- 3ファイルの per-file 集計値（total_lines / packed / memory 系）も一致。

判定:

- K1入口の lane差分は、candidate/map/disasm の3層で同値を確認できた。
- ここまでの更新は観測・比較・記録のみ（コード改変なし）。

---

## 58. `ROCBLAS_TENSILE_LIBPATH` A/B 実行時経路チェック（2026-03-25 14 JST）[main-node confirmed]

目的:

- 低レイヤ改造なしで、runtime path 差分が観測レイヤにどう出るかを確認する。
- 固定条件は anchor のまま（`MODEL=gpt-oss:latest`, `NUM_BATCH=512`, `NUM_CTX=8192`, `NUM_PREDICT=128`, `ROCBLAS_LAYER=9`）。

実施:

- AETS lane:
  - `ROCBLAS_TENSILE_LIBPATH=/home/limonene/ROCm-project/ROCm-repos_AETS/rocBLAS/build-mi25-gfx900/release/rocblas-install/lib/rocblas/library`
  - link summary:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_link_summary_gpt-oss_latest_20260325_135852.txt`
- system lane:
  - `ROCBLAS_TENSILE_LIBPATH=/opt/rocm-7.2.0/lib/rocblas/library`
  - strace raw prefix:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/g4_strace_openat_gpt-oss_latest_20260325_140141.log*`
  - rocprof summary:
    - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/rocprofv3_summary_gpt-oss_latest_20260325_140345.txt`
- A/B compare summary:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_runtime_path_ab_compare_20260325_140536.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_runtime_path_ab_compare_20260325_140536.tsv`

確認結果（facts）:

- AETS lane:
  - `fallback_confirmed=1`
  - `dispatch_confirmed=1`
  - `direct_rocblas_or_tensile_dispatch=1`
  - `fallback_dat_openat=56`, `fallback_hsaco_openat=56`
  - `rocblas_trace_gemm_lines=1002`
  - `kernel_dispatch_rows=21664`, `kernel_tensile_like_rows=167`
  - `phase_split_status_proxy=decode_signature_detected`
- system lane:
  - `fallback_confirmed=0`
  - `dispatch_confirmed=0`
  - `direct_rocblas_or_tensile_dispatch=0`
  - `fallback_dat_openat=0`, `fallback_hsaco_openat=0`
  - `rocblas_trace_gemm_lines=0`
  - `kernel_dispatch_rows=0`, `kernel_tensile_like_rows=0`
  - `phase_split_status_proxy=unavailable`
- system lane strace では `librocblas.so.5` が `/opt/rocm-7.2.0/lib/librocblas.so.5` から解決されることを再確認。

補足（tooling）:

- 現行 `g4-fallback-strace-check.sh` は fallback `.dat/.hsaco` が 0 件の場合に `rg` の戻り値で early-exit するため、system lane は raw strace から手動集計した。
- ここでの結論は観測差分のみ。catalog 項目と decode 計算の 1:1 因果は未確定のまま。

判定:

- anchor 条件では runtime path によって観測結果が大きく分岐しうることを確認。
- 次段は引き続き「観測→比較→記録」を維持し、過剰な因果断定を避ける。

---

## 59. 1shape 入口ループ（K1: `512x512x2880`）開始 (2026-03-25 14 JST) [main-node confirmed]

目的:

- 「本命 shape を1個だけ」で低レイヤ最適化入口を開始する。
- 改造前提ではなく、観測→比較→記録を同一命名で固定する。

実施:

- 新規スクリプト:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/g4-k1-single-shape-loop.sh`
- 実行:

```bash
cd /home/limonene/ROCm-project/ROCm-MI25-build
RUN_TAG=k1_entry_20260325_1shape \
MODEL=gpt-oss:latest NUM_BATCH=512 NUM_CTX=8192 NUM_PREDICT=128 \
KEEP_ALIVE=5m STREAM=1 ROCBLAS_LAYER=9 \
TARGET_M=512 TARGET_N=512 TARGET_K=2880 \
./g4-k1-single-shape-loop.sh
```

証跡:

- summary:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_loop_k1_entry_20260325_1shape.txt`
- tsv:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_loop_k1_entry_20260325_1shape.tsv`
- index:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_loop_k1_entry_20260325_1shape_index.tsv`

確認結果（facts）:

- one-point change:
  - `ROCBLAS_TENSILE_LIBPATH` のみ lane 間で変更（AETS vs system）
- target shape:
  - `512x512x2880`
- AETS lane:
  - `fallback_confirmed=1`, `dispatch_confirmed=1`, `direct_rocblas_or_tensile_dispatch=1`
  - `shape_target_hits=192`
  - `ttft_ms=12258.629`, `total_ms=14904.098`, `tok_s=49.8367`
- system lane:
  - `fallback_confirmed=0`, `dispatch_confirmed=0`, `direct_rocblas_or_tensile_dispatch=0`
  - `shape_target_hits=0`
  - `ttft_ms=15783.122`, `total_ms=39508.229`, `tok_s=5.2899`

補足（tooling）:

- `g4-fallback-strace-check.sh` の fallback 0件時 early-exit を修正し、
  system lane でも同一手順で summary を生成できるようにした。

判定:

- 「1shape 固定→A/B 比較→記録」の入口ループが成立。
- 次段はこの `RUN_TAG` 命名フォーマットを維持し、shape を増やさず同じ対象で再測定を重ねる。

---

## 60. 1shape 反復再測定（初回+r1+r2）と安定性集約 (2026-03-25 14 JST) [main-node confirmed]

目的:

- 1shape 入口ループの再現性を、同条件の反復で確認する。
- shape を増やさず、`ROCBLAS_TENSILE_LIBPATH` の one-point A/B を維持する。

実施:

- 再測定:
  - `RUN_TAG=k1_entry_20260325_1shape_rerun1`
  - `RUN_TAG=k1_entry_20260325_1shape_rerun2`
- 集約補助:
  - `/home/limonene/ROCm-project/ROCm-MI25-build/summarize-k1-single-shape-repeats.sh`
  - 実行:
    - `RUN_ROOT=k1_entry_20260325_1shape ./summarize-k1-single-shape-repeats.sh`

証跡:

- rerun1:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_loop_k1_entry_20260325_1shape_rerun1.tsv`
- rerun2:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_loop_k1_entry_20260325_1shape_rerun2.tsv`
- repeat summary:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_repeat_summary_k1_entry_20260325_1shape_20260325_143343.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_repeat_summary_k1_entry_20260325_1shape_20260325_143343.tsv`

確認結果（facts）:

- AETS lane（3 run）:
  - `fallback/dispatch/direct` は全runで `1`（`all_same=1`）
  - `shape_hits_mode=192`（`all_same=1`）
  - `ttft_ms(avg/min/max)=12420.169/12258.629/12626.515`
  - `total_ms(avg/min/max)=15059.612/14904.098/15269.780`
  - `tok_s(avg/min/max)=49.8266/49.7468/49.8963`
- system lane（3 run）:
  - `fallback/dispatch/direct` は全runで `0`（`all_same=1`）
  - `shape_hits_mode=0`（`all_same=1`）
  - `ttft_ms(avg/min/max)=17003.929/14808.780/20419.886`
  - `total_ms(avg/min/max)=40334.107/37375.081/44119.010`
  - `tok_s(avg/min/max)=5.3880/5.2899/5.5733`

判定:

- 1shape 入口ループは、観測ラベルと shape hit の再現性が高い状態で維持できている。
- 次段は shape を増やさず、同対象で「1ノブだけ変える」比較へ進める。

---

## 61. 対照実験（1ノブ変更: `NUM_PREDICT=128 -> 256`）(2026-03-25 14 JST) [main-node confirmed]

目的:

- 1shape 入口ループを維持したまま、1ノブ変更の影響だけを確認する。
- 変更対象は `NUM_PREDICT` のみ（`128 -> 256`）。

固定条件:

- `MODEL=gpt-oss:latest`
- `NUM_BATCH=512`
- `NUM_CTX=8192`
- `KEEP_ALIVE=5m`
- `STREAM=1`
- `ROCBLAS_LAYER=9`
- target shape: `512x512x2880`
- lane差分は従来どおり `ROCBLAS_TENSILE_LIBPATH` のみ

実施:

- np256 反復:
  - `k1_entry_20260325_1shape_np256`
  - `k1_entry_20260325_1shape_np256_rerun1`
  - `k1_entry_20260325_1shape_np256_rerun2`
- np256 集約:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_repeat_summary_k1_entry_20260325_1shape_np256_20260325_144830.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_repeat_summary_k1_entry_20260325_1shape_np256_20260325_144830.tsv`
- 128 vs 256 比較:
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_control_compare_num_predict_128_vs_256_20260325_144910.txt`
  - `/home/limonene/ROCm-project/vega_path_check_logs_raw/summaries/g4_k1_single_shape_control_compare_num_predict_128_vs_256_20260325_144910.tsv`

確認結果（facts）:

- AETS lane:
  - phase: `decode_signature_detected` 維持
  - shape_hits_mode: `192 -> 192`（不変）
  - `ttft_ms_avg`: `12420.169 -> 12432.884`（+12.715）
  - `total_ms_avg`: `15059.612 -> 17869.656`（+2810.044）
  - `tok_s_avg`: `49.8266 -> 48.6955`（-1.1311）
  - `rocblas_trace_gemm_avg`: `1002 -> 1002`（不変）
- system lane:
  - phase: `unavailable` 維持
  - shape_hits_mode: `0 -> 0`（不変）
  - `ttft_ms_avg`: `17003.929 -> 15791.522`
  - `total_ms_avg`: `40334.107 -> 62182.247`
  - `tok_s_avg`: `5.3880 -> 5.4871`
  - dispatch/gemm 系は引き続き 0

判定:

- 1ノブ変更でも lane 分離（AETS=direct/shape-hitあり, system=なし）は維持された。
- ただし AETS lane の throughput は `NUM_PREDICT=256` で微減、`total_ms` は増加。
- 次段も shape を増やさず、単一ノブ比較を積み上げる方針を継続する。
