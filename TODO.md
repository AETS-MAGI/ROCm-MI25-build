# TODO

## 0. いまの到達点
- [x] `rocminfo` で MI25 / gfx900 を確認
- [x] CPU fallback を再現し、証跡を取得
- [x] `tinyllama-gpu-path-check.sh` で A/B 比較基盤を作成
- [x] `OLLAMA_LIBRARY_PATH` 先の backend 実体欠落を特定
- [x] `build-ollama-gfx900.sh` で backend (`libggml-hip.so` など) を再生成
- [x] 復旧後に `inference_library=ROCm` / `compute=gfx900` / `GPULayers` 復帰を確認
- [x] `tinyllama` で GPU 実行を再確認
- [x] `deepseek-r1:14b` を MI25 上で実行確認
- [x] worklog に原因・復旧・再評価を反映

## 1. 残務: 検証の仕上げ
- [x] A/B 実行で残っている `UNSURE` 1件を再走して確定する
- [x] `restart=0 / 1`、`warm-up=0 / 1`、`keep_alive=0s / 10m` の最終所見を短くまとめる
- [x] `deepseek-r1:14b` についても `journal` / `rocm-smi` / 生成結果を同時採取して証跡を固定する
- [x] MI25 と他GPU（必要なら 3060 / 9070XT）で簡易比較条件を決める
- [x] 速度比較用に同一プロンプト・同一 `num_predict` のベンチ手順を決める

## 2. 残務: 再発防止
- [x] `tinyllama-gpu-path-check.sh` に backend 実体 preflight を追加
- [x] systemd user service 側にも起動前チェックを入れる
- [x] `OLLAMA_LIBRARY_PATH` が壊れた symlink を向いていないか確認するチェックを追加
- [x] `libggml-hip.so` / `libggml-cpu*.so` の存在確認手順を `MI25_environment-setup.md` に昇格反映
- [x] backend 欠落時に「CPU fallback へ silently 移行」ではなく、即気づける運用メモを書く

## 3. 残務: ドキュメント整理
- [x] `MI25_environment-setup.md` に「検証済み構成」を追記
- [x] `MI25_environment-setup.md` に「backend 欠落時の症状」を追記
- [x] `MI25_environment-setup.md` に「確認コマンド集」を整理して載せる
- [x] `MI25_environment-setup-worklog.md` の節見出しを整えて読みやすくする
- [x] 証跡ファイル名一覧を worklog 末尾にまとめる
- [x] `ROCm-MI25-build` 側の README に今回の結論を反映する
- [x] README の関連ファイル欄を、実在するファイルだけに限定して最終確認する

## 4. 残務: スクリプト整理
- [x] `tinyllama-gpu-path-check.sh` のコメントを少し増やす
- [x] 出力 TSV の列説明を README か docs に追記する
- [x] `deepseek-r1-14b.sh` を汎用化する
- [x] モデル名を引数に取る共通検証スクリプトへ寄せる
- [x] `vega_path_check_logs/` のログ命名規則を簡単に定義する
- [x] 生成ログ・journal・rocm-smi の3点セットを1ユニットとして扱う説明を書く

## 5. 残務: モデル評価
- [x] `deepseek-r1:14b` の出力テンプレート調整可否を確認する
- [x] reasoning 表示 (`Thinking...`) が Ollama テンプレート由来か確認する
- [x] 日本語の自然さ・技術説明品質を簡単に確認する
- [x] 実用候補モデルを 1〜2 個追加で試す
- [x] MI25 16GB で現実的に運用できそうなモデル帯を整理する
- [ ] `gpt-oss:20b` の DL 完了後、同一手順（generate/journal/rocm-smi）で検証する

## 6. 残務: 共有・公開
- [x] AMD Developer Community / Discord に続報を書く（下書き作成）
- [ ] AMD Developer Community / Discord に続報を実投稿する
- [x] 日本語 forum に「MI25 / gfx900 / ROCm 7.2 / Ollama bring-up まとめ」を立てる（下書き作成）
- [ ] 日本語 forum に「MI25 / gfx900 / ROCm 7.2 / Ollama bring-up まとめ」を実投稿する
- [x] forum に固定スレ候補を数本立てる
- [x] GitHub / forum / pages の導線を整理する（設計案作成）
- [ ] GitHub / forum / pages の導線を公開リンクで確定する
- [x] `ROCm-MI25-build` を companion repo としてどう見せるか決める（方針文書化）
- [x] 必要なら英語版の短い成果要約を作る

## 7. 低優先だけどやるとよさそう
- [x] `tokens/sec` を簡易計算して記録する
- [x] `tinyllama` と `deepseek-r1:14b` の VRAM 使用量の目安を書く
- [ ] MI25 と Vega64 の差が出るか、余力があれば比較する
- [ ] backend 配備の健全性チェックを他スクリプトにも使い回せるよう関数化する

## 8. ひとこと結論
- [x] 大きな山は越えた
- [x] 残りは「仕上げ・整理・共有」