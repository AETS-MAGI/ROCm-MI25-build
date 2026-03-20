# ROCm-MI25-build の companion repo 方針

## 1. 位置づけ

`ROCm-MI25-build` は以下に集中する companion repository として扱う。

- 再現可能なセットアップ手順
- 検証スクリプト
- 証跡の索引と運用ルール
- 構成依存の注意点（backend 配備など）

実装本体の改変は、各 fork リポジトリ（rocBLAS/Tensile/Ollama）側で管理する。

## 2. 読者別の期待値

- 利用者: `README` と setup guide を見れば再現できる
- 調査者: worklog と証跡インデックスから経緯を追える
- 開発者: fork 側で patch を確認できる

## 3. README での見せ方（推奨）

最上部で 3 点を明記する。

1. 何が再現できるか
2. 何はこの repo の責務外か
3. 最短の導線（setup -> validate -> evidence）

## 4. 更新ポリシー

- 重大な検証更新は、必ず以下 3 箇所を同時更新
  - `README.md`
  - `MI25_environment-setup.md`
  - `MI25_environment-setup-worklog.md`
- 投稿文/告知文は `MI25_community-outreach-kit.md` で管理

## 5. 命名・運用ルール

- 「再現手順」は setup guide に集約
- 「時系列の事実」は worklog に集約
- 「公開向け文章」は outreach kit に集約
- 同内容を複数ファイルに二重管理しない
