# MI25 / gfx900 環境構築手順書（事実ベース）

本書は、ROCm 7.2 + MI25 (gfx900) 環境で、Ollama を含む実用セットアップを再現するための手順書です。
あくまでも今回の実作業で確認できた事実を優先し、未確認項目は明示してあります。

---

## 1. 目的と前提

### 目的

- MI25 / gfx900 で ROCm を認識させる。
- Ollama を導入し、モデル保存先を固定する。
- 可能なら source build で gfx900 向け設定を有効化する。
- 「GPUが見えている」ことと「推論計算に使われている」ことを分けて検証する。

### 前提

- Linux (Ubuntu 系) を想定。
- 作業ルートは `/home/user/ROCm-project` で一般化して記述。
- 一部手順は `sudo` 権限が必要。

---

## 2. 対象環境の整理

### 今回の実作業で確認できた環境（事実）

- OS: Ubuntu 24.04 (noble)
- ROCm: 7.2
- `rocminfo` で `gfx900` / `Radeon Instinct MI25` を確認
- `rocm-smi` で MI25 相当デバイスが表示

```bash
                             ....              limonene@hbmx-mi25
              .',:clooo:  .:looooo:.           ------------------
           .;looooooooc  .oooooooooo'          OS: Ubuntu 24.04.4 LTS (Noble Numbat) x86_64
        .;looooool:,''.  :ooooooooooc          Kernel: Linux 6.8.0-106-generic
       ;looool;.         'oooooooooo,          Uptime: 11 hours, 55 mins
      ;clool'             .cooooooc.  ,,       Packages: 1261 (dpkg)
         ...                ......  .:oo,      Shell: bash 5.2.21
  .;clol:,.                        .loooo'     Display (SHARP HDMI): 1920x1080 in 22", 60 Hz [External]
 :ooooooooo,                        'ooool     Terminal: node
'ooooooooooo.                        loooo.    CPU: AMD Ryzen 5 3400G (8) @ 3.70 GHz
'ooooooooool                         coooo.    GPU 1: AMD Instinct MI25/MI25x2/V340/V320 [Discrete]
 ,loooooooc.                        .loooo.    GPU 2: AMD Radeon Vega 11 Graphics [Integrated]
   .,;;;'.                          ;ooooc     Memory: 2.03 GiB / 29.29 GiB (7%)
       ...                         ,ooool.     Swap: 0 B / 8.00 GiB (0%)
    .cooooc.              ..',,'.  .cooo.      Disk (/): 41.44 GiB / 118.19 GiB (35%) - btrfs
      ;ooooo:.           ;oooooooc.  :l.       Disk (/home): 2.24 GiB / 238.47 GiB (1%) - btrfs
       .coooooc,..      coooooooooo.           Local IP (enp8s0): 192.168.1.187/24
         .:ooooooolc:. .ooooooooooo'           Locale: ja_JP.UTF-8
           .':loooooo;  ,oooooooooc
               ..';::c'  .;loooo:'                                     
                                                                       
```

### パス一般化ルール

- 実運用の手順は `/home/user/ROCm-project` を基準に記載。
- ローカル固有のパスやホスト名は「例」扱いにする。

---

## 3. インストール前の確認事項

### 3.1 基本チェック

```bash
cat /etc/os-release
uname -r
id
```

なぜ必要か:
- 手順の対象OSか、権限作業が可能かを先に確定するため。

### 3.2 GPU認識チェック（見えているか）

```bash
lspci | rg -i "vga|display|amd|advanced micro devices"
rocminfo | rg -n "Name:|Marketing Name|gfx900|Agent"
rocm-smi
```

解釈:
- `rocminfo` に `gfx900` と MI25 名称が出れば、ROCmランタイム側で「GPUが見えている」。
- これは「推論に使えている」こととは別。

### 3.3 権限/グループ確認

```bash
id -nG
```

なぜ必要か:
- ROCm利用では `render` / `video` グループが必要になるケースがある。

---

## 4. 実際の構築手順

### 4.1 ROCm 7.2 の導入（Ubuntu 24.04 例）

```bash
sudo mkdir -p /etc/apt/keyrings
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg >/dev/null

cat <<'EOF' | sudo tee /etc/apt/sources.list.d/rocm.list
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2 noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/7.2/ubuntu noble main
EOF

cat <<'EOF' | sudo tee /etc/apt/preferences.d/rocm-pin-600
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

sudo apt update
sudo apt install -y rocm
sudo usermod -aG render,video "$USER"
sudo reboot
```

なぜ必要か:
- ROCm本体とユーザー権限を整え、再起動でデバイスノード/グループ反映を確実にするため。

注意:
- 再起動を伴う。リモート作業時は接続断に注意。

### 4.2 Ollama 導入 + モデル保存先固定

前提スクリプト:
- `ollama-setup.sh`

実行例（一般化パス）:

```bash
cd /home/user/ROCm-project
./ollama-setup.sh --service user
```

このスクリプトで行うこと（実装済み）:
- `OLLAMA_MODELS=/home/user/ROCm-project/ollama-models` に固定
- `HSA_OVERRIDE_GFX_VERSION=9.0.0` を設定
- MI25向け保守設定（`OLLAMA_NUM_PARALLEL=1` など）

### 4.3 gfx900 向け source build（必要時）

前提スクリプト:
- `build-ollama-gfx900.sh`

実行例:

```bash
cd /home/user/ROCm-project
./build-ollama-gfx900.sh --ref v0.18.2
```

フォーク利用時の例（AETS 版など）:

```bash
cd /home/user/ROCm-project
./build-ollama-gfx900.sh --repo-url https://github.com/<org-or-user>/<forked-ollama-repo>.git --ref main
```

補足:
- CMake 構成で `GPU_TARGETS=gfx900` と `AMDGPU_TARGETS=gfx900` を指定。
- `--repo-url` 未指定時は upstream (`https://github.com/ollama/ollama.git`) を使う。

危険操作の注意:
- 生成ライブラリを `/usr/local/lib/ollama/rocm/libggml-hip.so` に上書きする手順は、既存Ollama実行環境を壊す可能性がある。
- 必ずバックアップを取り、停止中に差し替えること。

---

## 5. 動作確認手順

### 5.1 ROCm 側

```bash
rocminfo | rg -n "gfx900|Marketing Name"
rocm-smi
```

期待:
- `gfx900` と MI25 名称が表示される。

### 5.2 Ollama 側

```bash
systemctl --user status ollama --no-pager
systemctl --user show ollama -p ExecStart -p Environment
curl -s http://127.0.0.1:11434/api/version
curl -s http://127.0.0.1:11434/api/tags
ollama list
```

期待:
- service が `active (running)`
- API 応答が返る
- `ExecStart` が意図したバイナリ（例: `/home/user/ROCm-project/ollama-src/ollama`）になっている

### 5.3 Verified working state（検証済みの動作状態）

現時点で再現できた「動いた経路」は以下。

- `rocBLAS/Tensile(gfx900)` の local build を完了。
- `ROCBLAS_TENSILE_LIBPATH` を `ollama` user service に注入。
- 実際の `/api/generate` を 1 回実行して完了レスポンスを取得。
- 同時刻の `rocm-smi` 採取で MI25 負荷上昇を確認。
- `journalctl` で `library=ROCm` / `compute=gfx900` / `Radeon Instinct MI25` を確認。

### 5.4 Evidence collected（採取済み証跡）

証跡ファイル（ファイル名のみ）:

- `rocblas_gfx900_build_retry_20260320_171312.log`
- `ollama_generate_20260320_174327.json`
- `rocm_smi_during_generate_20260320_174327.log`
- `ollama_journal_after_test_20260320_174327.log`

補足:
- 時系列の観測詳細は `MI25_environment-setup-worklog.md` を参照。
- 本書では「現在の動作経路」を短く示す。

---

## 6. よくある詰まりどころ

### 6.1 `ollama pull` で接続失敗

症状例:
- `could not connect to ollama server`

切り分け:

```bash
systemctl --user status ollama --no-pager
curl -s http://127.0.0.1:11434/api/version
```

原因候補:
- service 未起動
- system service と user service の競合

### 6.2 モデル保存先の権限エラー

症状例:
- `permission denied: ensure path elements are traversable`

切り分け:

```bash
namei -l /home/user/ROCm-project/ollama-models
ls -ld /home/user/ROCm-project/ollama-models
```

対処例:

```bash
sudo chown -R "$USER:$USER" /home/user/ROCm-project/ollama-models
chmod -R u+rwX /home/user/ROCm-project/ollama-models
```

補足:
- system service 運用時は `ollama` ユーザーが親ディレクトリを辿れる必要がある。

### 6.3 systemd の二重起動競合

症状:
- system service が restart loop
- user service は active

整理手順:

```bash
sudo systemctl disable --now ollama
systemctl --user enable --now ollama
```

### 6.4 起動バイナリとライブラリ取り違え

症状:
- source build 済みなのに期待どおり動かない

確認コマンド:

```bash
systemctl --user cat ollama
systemctl --user show ollama -p ExecStart
which ollama
readlink -f "$(which ollama)"
ldd /home/user/ROCm-project/ollama-src/ollama
```

補足:
- まず `ExecStart` を絶対パスで固定し、PATH 依存を排除する。
- `buildできた` と `そのバイナリでservice運用している` は別確認が必要。

---

## 7. GPU が使われているかの確認方法

この章が最重要。

### 7.1 「見えている」確認（可視性）

コマンド:

```bash
rocminfo | rg -n "gfx900|Marketing Name"
rocm-smi
```

判定基準:
- `rocminfo` に `gfx900` / `Radeon Instinct MI25` が表示されること。
- `rocm-smi` にMI25系デバイスが表示されること。

### 7.2 「実際に計算に使っている」確認（計算実行）

コマンド:

```bash
journalctl --user -u ollama --no-pager -n 200 | rg -n "discovering available GPUs|inference compute|library=|compute=gfx900|Radeon Instinct MI25|failure during GPU discovery" -i
curl -s http://127.0.0.1:11434/api/generate -d '{"model":"tinyllama","prompt":"hello","stream":false}'
rocm-smi --showuse --showmemuse --showpower --showtemp --alldevices
```

解釈:
- `inference compute ... library=ROCm` かつ `compute=gfx900` が出ることを確認する。
- 同じ生成リクエスト中に `rocm-smi` 側で MI25 の負荷/電力が上がることを確認する。
- `failure during GPU discovery` や `library=cpu` が出る場合は CPUフォールバックの可能性を再点検する。

補足:
- 実作業での観測結果は `MI25_environment-setup-worklog.md` に集約する。
- 本書は手順書として、再現手順と判定方法のみを維持する。

### 7.3 Known environment-specific assumptions（環境依存の前提）

- Ubuntu 24.04 + ROCm 7.2 前提で検証。
- MI25/gfx900 での確認結果であり、他GPU世代へはそのまま一般化しない。
- local `rocBLAS/Tensile(gfx900)` を使う構成を前提にしている。
- `HSA_OVERRIDE_GFX_VERSION=9.0.0` などの実行時設定に依存する場合がある。
- 単発生成の成功は確認済みだが、長時間安定性や全モデル互換は未確定。

---

## 8. gfx900 / MI25 固有の注意点

- gfx900 はコンポーネントによってデフォルト対象外になることがある。
- source build で `GPU_TARGETS` / `AMDGPU_TARGETS` を明示しても、実行時互換性が別途必要な場合がある。
- `HSA_OVERRIDE_GFX_VERSION=9.0.0` は回避策として使われるが、GPU利用成功を保証しない。
- 低負荷時 `rocm-smi` の low-power 警告は必ずしも異常ではない。

---

## 9. 参考資料

ROCm-vega 配下で参照推奨（ファイル名ベース）:

- `work_logs.md`: 実作業の時系列ログ
- `facts.md`: 事実台帳（確定事項の整理）
- `knowns_unknowns.md`: 既知/未確定の切り分け
- `support_boundary.md`: どこまでが公開情報で追えるかの境界
- `what_can_be_extended.md`: source-build で拡張可能な層
- `vega-rocm.md`: 調査全体の本体ドキュメント
- `gfx900_int8_path_inventory.md`: gfx900 INT8 経路の整理

---

## 10. 作業ログの扱い

- 実行ログ、観測結果、暫定結論、セッション復旧メモは `MI25_environment-setup-worklog.md` に記録する。
- 本書には、再現可能なセットアップ手順と検証手順のみを残す。
