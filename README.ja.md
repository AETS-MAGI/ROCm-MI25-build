# ROCm-MI25-build

[English](README.md) | [日本語](README.ja.md)

AMD MI25 (gfx900) + ROCm 7.2 + Ollama の bring-up 検証を行うための、実験用ビルド/運用ワークスペースです。

## 目的

- MI25/gfx900 環境構築を再現しやすいスクリプト群を提供する。
- 検証済みの構成経路と、時系列の調査ログを分離して管理する。
- 実運用で使ったスクリプトと検証文書を同じ場所で保守する。

## タスク管理

- 集約TODO: `../MI25_TODO/ROCm-MI25-build_TODO.md`

## 収録内容

- `rocm-install.sh`
  - Ubuntu 系向け ROCm インストール補助。
- `ollama-setup.sh`
  - MI25/gfx900 向け環境変数を含む Ollama user service 設定補助。
- `ollama-manual.sh`
  - モデル/ランタイム参照先を固定した手動起動補助（start/stop/status/run）。
- `build-ollama-gfx900.sh`
  - Ollama の gfx900 ターゲット source build 補助。
- `build-rocblas-gfx900.sh`
  - rocBLAS/Tensile(gfx900) の local build 補助。
- `g4-stream-phase-window-check.sh`
  - Stream モード（`stream=true`）で TTFT と prefill/decode proxy を同時取得する probe。
- `g4-stream-phase-window-sweep.sh`
  - stream probe を `num_predict` で一括スイープ（既定: `64,128,256,512,1024`）し、TSV で統合比較するランナー。
- `g4-stream-keepalive-sweep.sh`
  - stream probe の `keep_alive` 感度を比較するランナー（既定の安定セット: `10s,30s,5m`）。
- `g4-anchor-observation-status.sh`
  - 観測結果を安全な状態ラベルで返す最小UXラッパー（decode/fallback/dispatch/shape）。kernel因果の断定は行わない。
- `commit-no-raw.sh`
  - raw/probeログ（`vega_path_check_logs/`, `.rocprofv3/`）を除外してコミットする補助。
- `raw-log-one-line-index.sh`
  - raw ログカテゴリの1行索引TSVを生成する補助（dispatch-boundary 系のログ棚卸し向け）。
- `lib/backend-preflight.sh`
  - 検証スクリプト/手動起動スクリプトで共通利用する backend 健全性チェック。
- `mcp-rocm-ops/`
  - このワークスペース向け ROCm/Ollama 運用ツールの最小 MCP サーバー。
- `ROCm-MI25-tips/MI25_environment-setup.md`
  - 現在の動作経路を重視した手順書。
- `ROCm-MI25-tips/MI25_environment-setup-worklog.md`
  - 時系列の作業ログと証跡。
- `ROCm-MI25-tips/G4_gptoss_anchor_profile.md`
  - G4 観測アンカー（baseline/side）の正本プロファイル。
- `ROCm-MI25-tips/MI25_build-dependencies-map.md`
  - Ubuntu 24.04 bring-up で使った依存関係マップ。
- `ROCm-MI25-tips/MI25_gfx900_inference-success-summary_20260320.md`
  - 原因・復旧・検証結果を 1 ページでまとめた要約。
- `ROCm-MI25-tips/MI25_logging-and-benchmark-notes.md`
  - ログ命名規則、TSV 列説明、ベンチ比較条件メモ。
- `ROCm-MI25-tips/MI25_ollama_ux_minimum.md`
  - MI25/gfx900 向け `ollama run` の安全寄り最小UXガイド（anchor 条件限定）。
- `ROCm-MI25-tips/MI25_ollama_ux_minimum.ja.md`
  - 上記ガイドの日本語版。
- `ROCm-MI25-tips/MI25_community-outreach-kit.md`
  - Community/forum/pages 向け投稿下書きと導線設計。
- `ROCm-MI25-tips/MI25_companion-repo-positioning.md`
  - companion repo の責務範囲と公開時の見せ方方針。

## ログ保管ポリシー（raw と summary の分離）

- `vega_path_check_logs/` はレビューしやすい要約証跡を置く場所です。
  - summary（`*.txt`）
  - 集計テーブル（`*.tsv`, `*.jsonl`）
- raw/probe 系の重い成果物は、既定でリポジトリ外に保存します。
  - `${WORKSPACE_ROOT}/vega_path_check_logs_raw`
  - 例: `strace` 分割ログ、serve stdout/stderr、generate JSON、rocprof probe ディレクトリ

現行の probe スクリプト（g4 系 + 旧 model/tinyllama check）の出力先:

- summary 出力 -> `LOG_DIR`（既定: `${WORKSPACE_ROOT}/vega_path_check_logs_raw/summaries`）
- raw 出力 -> `RAW_LOG_DIR`（既定: `${WORKSPACE_ROOT}/vega_path_check_logs_raw`）

レビュー用に意図して `ROCm-MI25-build/vega_path_check_logs` へ置く場合は、明示指定します:

```bash
LOG_DIR=/path/to/ROCm-MI25-build/vega_path_check_logs ./<probe-script>.sh
```

補助コマンド:

```bash
# 既存 in-repo raw ログを外部 raw ディレクトリへ移行（既定: move）
./migrate-raw-logs.sh

# 原本を残してコピーのみ行う場合
MODE=copy ./migrate-raw-logs.sh

# 外部 raw ログを圧縮（既定: 原本保持）
./compress-raw-logs.sh

# 圧縮後に原本を置換
KEEP_ORIGINAL=0 ./compress-raw-logs.sh

# raw ログ棚卸し用の1行索引を生成（既定ラベル: dispatch-boundary）
./raw-log-one-line-index.sh
```

注意:

- `.gitignore` で `vega_path_check_logs/` 配下の raw/probe 成果物は追跡対象外にしています。
- すでに git 履歴に入っている過去ログは、`.gitignore` 追加だけでは履歴から消えません。
- `MODE=move` では、退避先に同一ファイルがある場合に元側の重複を削除します。
- stream+rocprof の phase-window 観測では、`keep_alive=0s` や極端に短い値で
  rocprof CSV が空になり `phase_split_status_proxy=unavailable` になる場合があります。
  安定観測には `keep_alive>=10s` を推奨します。

## Anchor 観測の最小UX（安全ラベル表示）

「勝利宣言」ではなく、現在の観測事実を安全に表示したい場合は次を使います。

```bash
cd /path/to/ROCm-MI25-build
./g4-anchor-observation-status.sh
```

side lane（`num_batch=1024`）で確認する場合:

```bash
LANE=side ./g4-anchor-observation-status.sh
```

出力される主ラベル:

- `decode_signature_label=decode_signature_observed|decode_signature_not_observed`
- `fallback_label=fallback_confirmed|fallback_not_confirmed`
- `dispatch_label=dispatch_confirmed|dispatch_not_confirmed`
- `shape_match_note=shape_match_observed|shape_match_not_observed_or_out_of_target_set`

安全ガード（断定回避）:

- `anchor_scope_note=anchor_condition_limited_to_current_probe`
- `anchor_scope_match=0|1`
- `kernel_mapping_note=...pending...`
- `generalization_note=do_not_generalize_to_other_workloads_without_revalidation`

補足:

- これは anchor 条件限定の状態表示です（solver/kernel 因果の最終断定ではありません）。
- `catalog-read` と `dispatch` は別レイヤ証拠として表示します。

## 想定ディレクトリ構造

各スクリプトは、次のワークスペース構造を前提にしています。

```text
/home/$USER/ROCm-project/
  ROCm-MI25-build/
  ollama-src/
  ROCm-repos_AETS/
    rocBLAS/
    Tensile/
```

この配置と異なる場合は、各スクリプトの CLI オプション（例: `--src-dir`, `--tensile-dir`, `--models-dir`）で明示指定するか、下記の bootstrap を使って標準配置を作成してください。

## 自動クローンと配置（bootstrap）

必要なリポジトリを想定構造へ自動配置するには次を実行します。

```bash
cd /path/to/ROCm-MI25-build
./bootstrap-workspace.sh
```

オプション例:

```bash
# 実行せずに計画だけ確認
./bootstrap-workspace.sh --dry-run

# ルートディレクトリを変更
./bootstrap-workspace.sh --root-dir /data/ROCm-project
```

このスクリプトで準備される主な配置:

- `ROCm-MI25-build`
- `ollama-src`
- `ROCm-repos_AETS/rocBLAS`
- `ROCm-repos_AETS/Tensile`

## スコープ

- 本リポジトリは実験検証用であり、公式サポートや互換性保証を示すものではありません。
- 結果は環境依存のため、対象マシンごとの再検証が必要です。

## 現時点の検証結論

- MI25/gfx900 の推論経路は、このワークスペースで実用可能であることを確認済みです。
- 不安定化の主因は MI25 の非対応ではなく、backend ランタイムライブラリ配置の不整合でした。
- backend 復旧後、`tinyllama` と `deepseek-r1:14b` の両方で GPU offload 証跡を確認しました。

## ブランチ方針

- `main` を基準枝とします。
- 今後の実験作業は `vega-int8-probe` で進めます。

## 関連リポジトリ

コンポーネント改変用の fork は別リポジトリで管理します。

- `rocBLAS-gfx900_aets-lab`
- `Tensile-gfx900_aets-lab`
- `ollama-gfx900_aets-lab`

このリポジトリは、セットアップスクリプト・文書・証跡整理を主目的にします。

## 公開リンク

- ROCm-MI25-build: https://github.com/AETS-MAGI/ROCm-MI25-build
- ollama-gfx900_aets-lab: https://github.com/AETS-MAGI/ollama-gfx900_aets-lab
- ollama-gfx900-starter-kit: https://github.com/AETS-MAGI/ollama-gfx900-starter-kit
- vega-hbmx-pages: https://github.com/AETS-MAGI/vega-hbmx-pages
- vega-hbmx-pages (GitHub Pages): https://aets-magi.github.io/vega-hbmx-pages/

## ライセンス

本リポジトリは Apache-2.0 で提供します。`LICENSE` と `NOTICE` を参照してください。

各コンポーネントの upstream ライセンスは、元の upstream/fork リポジトリで維持されます。

## 運用ポリシー文書

- コントリビューション: `CONTRIBUTING.md`
- セキュリティポリシー: `SECURITY.md`
