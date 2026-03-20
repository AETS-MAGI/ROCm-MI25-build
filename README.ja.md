# ROCm-MI25-build

[English](README.md) | [日本語](README.ja.md)

AMD MI25 (gfx900) + ROCm 7.2 + Ollama の bring-up 検証を行うための、実験用ビルド/運用ワークスペースです。

## 目的

- MI25/gfx900 環境構築を再現しやすいスクリプト群を提供する。
- 検証済みの構成経路と、時系列の調査ログを分離して管理する。
- 実運用で使ったスクリプトと検証文書を同じ場所で保守する。

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
- `ROCm-MI25-tips/MI25_environment-setup.md`
  - 現在の動作経路を重視した手順書。
- `ROCm-MI25-tips/MI25_environment-setup-worklog.md`
  - 時系列の作業ログと証跡。
- `ROCm-MI25-tips/MI25_build-dependencies-map.md`
  - Ubuntu 24.04 bring-up で使った依存関係マップ。
- `ROCm-MI25-tips/MI25_gfx900_inference-success-summary_20260320.md`
  - 原因・復旧・検証結果を 1 ページでまとめた要約。
- `ROCm-MI25-tips/MI25_logging-and-benchmark-notes.md`
  - ログ命名規則、TSV 列説明、ベンチ比較条件メモ。
- `ROCm-MI25-tips/MI25_community-outreach-kit.md`
  - Community/forum/pages 向け投稿下書きと導線設計。
- `ROCm-MI25-tips/MI25_companion-repo-positioning.md`
  - companion repo の責務範囲と公開時の見せ方方針。

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

## ライセンス

本リポジトリは Apache-2.0 で提供します。`LICENSE` と `NOTICE` を参照してください。

各コンポーネントの upstream ライセンスは、元の upstream/fork リポジトリで維持されます。

## 運用ポリシー文書

- コントリビューション: `CONTRIBUTING.md`
- セキュリティポリシー: `SECURITY.md`
