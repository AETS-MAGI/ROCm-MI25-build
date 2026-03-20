# Contributing

## Scope

This repository is focused on reproducible MI25/gfx900 setup scripts,
validation steps, and evidence-oriented documentation.

## Before opening a change

- Keep `main` as baseline and use an experiment branch for active work.
- Prefer additive updates to logs and notes.
- Keep historical provenance clear (what was observed, where, and when).

## Commit expectations

- Use small, reviewable commits.
- Explain why the change is needed, not only what changed.
- Include evidence paths for runtime-affecting changes when possible.

## Documentation updates

- Update both English and Japanese docs when changing repository-level guidance.
- Do not rewrite historical conclusions without adding new dated evidence.

## Scripts and safety

- Avoid destructive operations by default.
- Use explicit paths or CLI options when assumptions may vary.
- Validate shell scripts with `bash -n` before submitting.

## License

By contributing, you agree that your contributions are licensed under
Apache-2.0 as defined in `LICENSE`.

