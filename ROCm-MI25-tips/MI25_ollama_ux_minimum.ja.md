# MI25 Ollama 最小UXガイド（Anchor 条件限定）

最終更新: 2026-03-25  
対象: MI25/gfx900 ワークスペースで再現できている観測事実を、安全側で表示・運用するための最小ガイド。

## 1. スコープとガードレール

この文書は意図的に保守的です。

- 再現済みの観測ラベルを示す。
- kernel レベルの厳密因果は断定しない。
- anchor 条件で再検証していない範囲へ一般化しない。

状態ラベルは次を使います。

- `decode_signature_observed|not_observed`
- `fallback_confirmed|not_confirmed`
- `dispatch_confirmed|not_confirmed`
- `shape_match_observed|not_observed_or_out_of_target_set`

常に次の前提を維持します。

- `kernel-level causal mapping pending`

## 2. MI25/gfx900 の安全運用条件

日常運用と安定観測を両立するための推奨値:

- `keep_alive`: `>=10s` を推奨（stream/phase 観測の安定化）。
- 実運用既定: `5m`。
- anchor lane:
  - baseline lane: `num_batch=512`
  - side lane: `num_batch=1024`
- anchor context:
  - `num_ctx=8192`
  - `rocblas_layer=9`（観測 lane）

実行時パスは明示固定を維持します。

- `OLLAMA_LIBRARY_PATH` -> `ollama-src/build-gfx900/lib/ollama`
- `ROCBLAS_TENSILE_LIBPATH` -> AETS rocBLAS build の `.../rocblas/library`

## 3. `ollama run` の最小既定（安全優先）

通常の対話実行:

```bash
OLLAMA_KEEP_ALIVE=5m ollama run <model>
```

必要時に `ollama run` 内で安全パラメータを指定:

```text
/set parameter num_ctx 8192
/set parameter num_batch 512
```

side 比較だけ行う場合:

```text
/set parameter num_batch 1024
```

API 実行では `options.num_ctx`, `options.num_batch`, `keep_alive` を明示指定します。

## 4. 1コマンド観測ステータス（最小UX）

anchor 条件限定の安全ラベル表示:

```bash
cd /path/to/ROCm-MI25-build
./g4-anchor-observation-status.sh
LANE=side ./g4-anchor-observation-status.sh
```

出力には次のガードフィールドが含まれます。

- `anchor_condition_limited_to_current_probe`
- `kernel-level causal mapping pending`
- `do_not_generalize_to_other_workloads_without_revalidation`

## 5. 将来の upstream 還元候補

ここは候補整理であり、upstream 実装完了を意味しません。

1. `decode/fallback/dispatch` の観測ステータスを診断出力で明示する。
2. 過剰一般化を防ぐ `anchor_scope` 表示を加える。
3. `keep_alive` が短すぎる際の観測不安定化を警告する。
4. lane 別 shape ヒント（`*x512x*` / `*x1024x*`）を表示する。
5. `catalog-read` と `dispatch` を既定で分離表示する。

## 6. この文書の非目標

- solver レベルの最終因果断定はしない。
- catalog 項目と decode 計算単位の strict 1:1 対応を主張しない。
- anchor 条件の結果を全 workload へ自動適用しない。
