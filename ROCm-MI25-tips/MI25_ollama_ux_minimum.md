# MI25 Ollama Safe UX Minimum (Anchor-limited)

Last updated: 2026-03-25  
Scope: MI25/gfx900 workspace UX guidance based on currently reproducible observations.

## 1. Scope and guardrails

This note is intentionally conservative.

- It reports reproducible observation labels.
- It does **not** claim strict kernel-level causality.
- It is limited to the current anchor condition unless revalidated.

Use these labels as state indicators:

- `decode_signature_observed|not_observed`
- `fallback_confirmed|not_confirmed`
- `dispatch_confirmed|not_confirmed`
- `shape_match_observed|not_observed_or_out_of_target_set`

Always keep this guard in mind:

- `kernel-level causal mapping pending`

## 2. Safe operating conditions (MI25/gfx900)

Recommended baseline for stable observation and day-to-day MI25 operation:

- `keep_alive`: use `>=10s` for stable stream/phase observability.
- practical default in this workspace: `5m`.
- anchor runtime lane:
  - baseline lane: `num_batch=512`
  - side lane: `num_batch=1024`
- anchor context:
  - `num_ctx=8192`
  - `rocblas_layer=9` (observation lane)

Runtime path should remain explicit and consistent:

- `OLLAMA_LIBRARY_PATH` -> `ollama-src/build-gfx900/lib/ollama`
- `ROCBLAS_TENSILE_LIBPATH` -> AETS rocBLAS build `.../rocblas/library`

## 3. Minimal `ollama run` defaults (safe-first)

For normal interactive use:

```bash
OLLAMA_KEEP_ALIVE=5m ollama run <model>
```

Inside `ollama run`, set safe parameters when needed:

```text
/set parameter num_ctx 8192
/set parameter num_batch 512
```

For side-lane comparison only:

```text
/set parameter num_batch 1024
```

If your run path is API-based, use `options.num_ctx`, `options.num_batch`, and
request-level `keep_alive` explicitly.

## 4. One-shot observation status UX

Use the wrapper for anchor-limited status output:

```bash
cd /path/to/ROCm-MI25-build
./g4-anchor-observation-status.sh
LANE=side ./g4-anchor-observation-status.sh
```

This returns observation labels and guard fields:

- `anchor_condition_limited_to_current_probe`
- `kernel-level causal mapping pending`
- `do_not_generalize_to_other_workloads_without_revalidation`

## 5. Candidate points to return upstream (future)

These are candidate UX/diagnostic improvements, not completed upstream changes:

1. Add observation-oriented status labels in diagnostics (`decode/fallback/dispatch`).
2. Add explicit `anchor_scope` marker to prevent accidental over-generalization.
3. Warn when too-short `keep_alive` can make phase observability unavailable.
4. Provide lane-aware shape-target hints (`*x512x*` vs `*x1024x*`) in tooling output.
5. Keep `catalog-read` and `dispatch` evidence as separate sections by default.

## 6. Non-goals in this note

- No solver-level “final cause” statement.
- No strict 1:1 mapping claim between catalog entry and decode compute unit.
- No claim that this anchor result automatically applies to all workloads.
