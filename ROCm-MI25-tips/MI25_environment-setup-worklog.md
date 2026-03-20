# MI25 / gfx900 環境構築 作業ログ

このファイルは実作業ログ専用です。
`MI25_environment-setup.md` は手順書として維持し、観測結果や暫定結論は本ファイルに集約します。

---

## 1. 今回の環境で確認できた事実 / 未確認事項

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

## 2. ドキュメント反映メモ（要約）

- ROCmでのGPU可視性確認と、Ollamaでの計算実行確認を分離して記述。
- `GPUが見える` と `GPUで計算している` を別判定に統一。
- Ollama の service 運用で起きる権限問題・競合問題の再現条件と対処を整理。
- gfx900 source build 成功と、CPUフォールバック継続を同時に明記。

---

## 3. 参照した主要メモ / ファイル名一覧

- `MI25_environment-setup.md`
- `work_logs.md`
- `what_can_be_extended.md`
- `support_boundary.md`
- `facts.md`
- `knowns_unknowns.md`
- `vega-rocm.md`

---

## 4. 追加で証拠取得するとよいコマンド一覧

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

## 5. ROCm-vega / ROCm-build との照合メモ

- `ROCm-vega` には「過去観測では rocBLAS の gfx900 出荷資産が厚かった」記述が残る。
- 今回の実機再現（ROCm 7.2.0 apt）では `rocblas/library` に `gfx900` 向け Tensile/Kernels 資産が見当たらず、runner で `rocBLAS error` が直接出る。
- `ROCm-build` 側の MIOpen debug build は `rocblas_DIR=/opt/rocm/lib/cmake/rocblas` を参照しており、現行ランタイム資産の影響を受ける構成である。

---

## 6. セッション復旧メモ（2026-03-20）

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

## 7. 最終認定試験ログ（2026-03-20）

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

## 8. 状態更新メモ（2026-03-20 追記）

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
