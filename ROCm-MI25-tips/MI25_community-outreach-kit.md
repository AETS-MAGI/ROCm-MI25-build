# MI25/gfx900 共有・公開キット

この文書は、`ROCm-MI25-build` の検証結果を外部へ共有するための下書き集です。

## 1. AMD Developer Community / Discord 続報テンプレート（英語）

```text
Title: MI25 (gfx900) ROCm 7.2 + Ollama bring-up: stable GPU path validated

Short update from our MI25 lab bring-up:

- Environment: Ubuntu 24.04, ROCm 7.2, Radeon Instinct MI25 (gfx900)
- Runtime: Ollama source build + local rocBLAS/Tensile(gfx900) path
- Validated models: tinyllama, deepseek-r1:14b, qwen2.5:7b
- Evidence: journal (library=ROCm, compute=gfx900, GPULayers), rocm-smi utilization/power, generate JSON

Key finding:
The dominant fallback cause was backend runtime library placement mismatch (missing/misaligned backend files), not intrinsic MI25 incompatibility.

After backend recovery, we consistently observed GPU offload on MI25.

Reference docs and scripts:
- Setup guide
- Worklog with evidence index
- Generic checker script for model path validation

If helpful, we can share a compact checklist for backend preflight and model path A/B validation.
```

## 2. 日本語 forum 投稿テンプレート（初回まとめ）

```text
タイトル案:
MI25 / gfx900 / ROCm 7.2 / Ollama bring-up 検証まとめ（GPU経路復旧）

本文案:
MI25(gfx900) で ROCm 7.2 + Ollama の推論経路を再検証した結果を共有します。

結論として、CPU fallback の主因は「MI25非対応そのもの」ではなく、backend ライブラリ配置不整合（欠落/参照ずれ）でした。
backend を再配置した後は、journal の `library=ROCm`, `compute=gfx900`, `GPULayers` と rocm-smi 高負荷を継続的に確認できました。

確認モデル:
- tinyllama
- qwen2.5:7b
- deepseek-r1:14b

証跡は generate JSON / journal / rocm-smi の3点セットで保存しています。
必要なら、再現用チェックリストとスクリプトを追記します。
```

## 3. forum 固定スレ候補（3本）

1. `MI25(gfx900) × ROCm 7.2 実測トラブルシュート集`
2. `Ollama on MI25: backend preflight と CPU fallback 切り分け`
3. `MI25 16GB の実運用モデル帯メモ（7B/14B 中心）`

## 4. GitHub / forum / pages 導線設計

最短導線の推奨:

1. pages トップ: 1ページ要約 + 主要リンク
2. GitHub (`ROCm-MI25-build`): 再現手順とスクリプト
3. forum: 経緯とQ&A（更新ログ）

公開リンク（確定済み）:

- ROCm-MI25-build: https://github.com/AETS-MAGI/ROCm-MI25-build
- ollama-gfx900_aets-lab: https://github.com/AETS-MAGI/ollama-gfx900_aets-lab
- ollama-gfx900-starter-kit: https://github.com/AETS-MAGI/ollama-gfx900-starter-kit
- vega-hbmx-pages (repo): https://github.com/AETS-MAGI/vega-hbmx-pages
- vega-hbmx-pages (site): https://aets-magi.github.io/vega-hbmx-pages/

forum / community 投稿先（URL確定は実投稿後）:

- AMD Developer Community thread URL: TBD
- Discord thread/message URL: TBD
- Japanese forum thread URL: TBD

リンク配置の推奨:

- pages には以下 4 リンクを固定配置
  - Setup guide
  - Worklog (evidence index)
  - One-page success summary
  - Issue/feedback 連絡先
- forum 本文の末尾に GitHub と pages の両方を掲載
- GitHub README に forum スレURLを追加（公開後）

## 5. 投稿前チェックリスト

- 個人情報・ローカルパスのマスク確認
- 断定表現と未検証推定の分離
- `ROCm-vega` 由来情報を historical として明記
- 最新証跡ファイル名の整合確認
