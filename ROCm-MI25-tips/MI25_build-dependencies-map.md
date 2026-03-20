# MI25 / gfx900 ビルド依存関係マップ（Ubuntu 24.04 LTS）

このメモは、ROCm 7.2 + MI25(gfx900) で以下を進めるときの依存関係を整理したものです。

- Ollama source build / 実行
- rocBLAS + Tensile(gfx900) の自前ビルド
- 切り分けログ取得

---

## 1. 前提

- OS: Ubuntu 24.04 LTS (noble)
- ROCm: 7.2 系が導入済み（`/opt/rocm` が有効）

ROCm 未導入の場合は、先に `rocm-install.sh` 相当の手順で ROCm を入れてから進める。

---

## 2. まず入れる共通パッケージ

```bash
sudo apt update
sudo apt install -y \
	git curl wget ca-certificates gnupg \
	build-essential pkg-config \
	cmake ninja-build \
	python3 python3-pip python3-venv python3.12-venv \
	libmsgpack-cxx-dev libmsgpack-dev \
	gfortran \
	jq strace
```

用途メモ:

- `python3-venv` / `python3.12-venv`
	- rocBLAS ビルド時の Tensile virtualenv 作成に必須
- `libmsgpack-cxx-dev` / `libmsgpack-dev`
	- Tensile/rocBLAS CMake の `msgpack-cxx` 検出に必須
- `gfortran`
	- rocBLAS build helper が参照する Fortran コンパイラ
- `strace`
	- runner `SIGABRT` 切り分けで使用

---

## 3. Ollama source build 向け

追加前提:

- Go ツールチェイン（`go`）
- ROCm clang/hipcc（`/opt/rocm/llvm/bin/clang++`, `hipcc`）

確認:

```bash
command -v go
command -v hipcc
/opt/rocm/llvm/bin/clang++ --version
```

`build-ollama-gfx900.sh` が内部で要求する主コマンド:

- `git`, `cmake`, `ninja`, `go`, `hipcc`

---

## 4. rocBLAS + Tensile(gfx900) 自前ビルド向け

今回の実作業で実際に詰まりやすかった依存:

1. `python3.12-venv` が無い
2. `msgpack-cxx` 開発ヘッダが無い

典型エラーと対処:

- エラー:
	- `The virtual environment was not created successfully because ensurepip is not available`
	- 対処: `sudo apt install -y python3-venv python3.12-venv`

- エラー:
	- `Could NOT find msgpack-cxx (missing: msgpack-cxx_DIR)`
	- 対処: `sudo apt install -y libmsgpack-cxx-dev libmsgpack-dev`

---

## 5. 最小チェックリスト

```bash
command -v git cmake ninja python3 go hipcc gfortran
python3 -m venv /tmp/venv-test && rm -rf /tmp/venv-test
dpkg -l | rg -i 'python3-venv|python3.12-venv|libmsgpack-cxx-dev|libmsgpack-dev'
```

---

## 6. 運用ルール（このプロジェクト向け）

- `ROCm-repos/00_legacy-repos/*` は参照元として扱う。
- 実装・改変・ビルドは `ROCm-repos_AETS/*` 側で行う。
- Tensile は legacy 側の痕跡を参照しつつ、AETS 側フォークで反映する。

