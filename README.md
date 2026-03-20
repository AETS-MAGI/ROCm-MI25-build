# ROCm-MI25-build

[English](README.md) | [日本語](README.ja.md)

Experimental build and validation workspace for AMD MI25 (gfx900) with ROCm 7.2 and Ollama runtime bring-up.

## Purpose

- Provide reproducible scripts for MI25/gfx900 environment setup and bring-up.
- Track validated configuration paths separately from chronological investigation logs.
- Keep experiment evidence and setup documentation close to the scripts used in practice.

## Contents

- `rocm-install.sh`
  - ROCm package installation helper for Ubuntu-based setup.
- `ollama-setup.sh`
  - Ollama user-service setup helper with MI25/gfx900-oriented environment options.
- `build-ollama-gfx900.sh`
  - Source build helper for Ollama with gfx900 target configuration.
- `build-rocblas-gfx900.sh`
  - rocBLAS/Tensile(gfx900) local build helper.
- `ROCm-MI25-tips/MI25_environment-setup.md`
  - Current setup guide (validated path focused).
- `ROCm-MI25-tips/MI25_environment-setup-worklog.md`
  - Chronological worklog and collected evidence.
- `ROCm-MI25-tips/MI25_build-dependencies-map.md`
  - Dependency map used during Ubuntu 24.04 bring-up.

## Expected directory layout

The scripts assume this workspace layout:

```text
/home/$USER/ROCm-project/
  ROCm-MI25-build/
  ollama-src/
  ROCm-repos_AETS/
    rocBLAS/
    Tensile/
```

If you place this repository elsewhere, pass explicit paths to each script using their CLI options (for example `--src-dir`, `--tensile-dir`, `--models-dir`) or bootstrap the standard layout.

## Bootstrap workspace automatically

Use the helper script to clone and place required repositories into the expected layout:

```bash
cd /path/to/ROCm-MI25-build
./bootstrap-workspace.sh
```

Optional examples:

```bash
# preview actions only
./bootstrap-workspace.sh --dry-run

# choose a custom root
./bootstrap-workspace.sh --root-dir /data/ROCm-project
```

The script prepares:

- `ROCm-MI25-build`
- `ollama-src`
- `ROCm-repos_AETS/rocBLAS`
- `ROCm-repos_AETS/Tensile`

## Scope and non-goals

- This repository is for experimental lab validation, not an official compatibility statement.
- Results are environment-dependent and should be revalidated on each target machine.

## Branch policy

- `main` is the baseline branch.
- Ongoing experiment work is tracked on `vega-int8-probe`.

## Relationship to other repos

- Code forks for component-level modifications live in separate repositories:
  - `rocBLAS-gfx900_aets-lab`
  - `Tensile-gfx900_aets-lab`
  - `ollama-gfx900_aets-lab`
- This repository focuses on setup scripts, documentation, and evidence organization.

## License

This repository primarily contains scripts and documentation. Upstream component licenses remain in their original upstream/fork repositories.
