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

## スコープ

- 本リポジトリは実験検証用であり、公式サポートや互換性保証を示すものではありません。
- 結果は環境依存のため、対象マシンごとの再検証が必要です。

## 関連リポジトリ

コンポーネント改変用の fork は別リポジトリで管理します。

- `rocBLAS-gfx900_aets-lab`
- `Tensile-gfx900_aets-lab`
- `ollama-gfx900_aets-lab`

このリポジトリは、セットアップスクリプト・文書・証跡整理を主目的にします。

## ライセンス

本リポジトリは主にスクリプトと文書で構成されます。各コンポーネントの upstream ライセンスは、元の upstream/fork リポジトリで維持されます。
