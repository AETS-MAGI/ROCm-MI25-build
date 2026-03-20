#!/usr/bin/env bash

set -euo pipefail

ROCM_VERSION="7.2"
UBUNTU_CODENAME="noble"
KEYRING_PATH="/etc/apt/keyrings/rocm.gpg"
ROCM_LIST_PATH="/etc/apt/sources.list.d/rocm.list"
PIN_PATH="/etc/apt/preferences.d/rocm-pin-600"

usage() {
	cat <<'EOF'
Usage: ./rocm-install.sh [--no-reboot] [--yes]

Options:
	--no-reboot   Do not reboot automatically at the end
	--yes         Non-interactive install for apt (passes -y)
	-h, --help    Show this help
EOF
}

NO_REBOOT=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--no-reboot)
			NO_REBOOT=1
			shift
			;;
		--yes)
			ASSUME_YES=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage
			exit 1
			;;
	esac
done

require_cmd() {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Required command not found: $cmd" >&2
		exit 1
	fi
}

require_cmd sudo
require_cmd wget
require_cmd gpg
require_cmd apt

if [[ -r /etc/os-release ]]; then
	# shellcheck disable=SC1091
	source /etc/os-release
else
	echo "/etc/os-release not found. Unsupported environment." >&2
	exit 1
fi

if [[ "${ID:-}" != "ubuntu" || "${VERSION_CODENAME:-}" != "$UBUNTU_CODENAME" ]]; then
	echo "This script is intended for Ubuntu ${UBUNTU_CODENAME}." >&2
	echo "Detected: ID=${ID:-unknown}, VERSION_CODENAME=${VERSION_CODENAME:-unknown}" >&2
	exit 1
fi

echo "[1/6] Creating keyring directory"
sudo mkdir -p /etc/apt/keyrings

echo "[2/6] Installing ROCm repository key"
wget -qO- https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor | sudo tee "$KEYRING_PATH" >/dev/null

echo "[3/6] Writing ROCm apt repository list"
cat <<EOF | sudo tee "$ROCM_LIST_PATH" >/dev/null
deb [arch=amd64 signed-by=$KEYRING_PATH] https://repo.radeon.com/rocm/apt/$ROCM_VERSION $UBUNTU_CODENAME main
deb [arch=amd64 signed-by=$KEYRING_PATH] https://repo.radeon.com/graphics/$ROCM_VERSION/ubuntu $UBUNTU_CODENAME main
EOF

echo "[4/6] Writing apt pin preferences"
cat <<'EOF' | sudo tee "$PIN_PATH" >/dev/null
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

echo "[5/6] Updating apt index"
sudo apt update

echo "[6/6] Installing rocm meta package"
if [[ $ASSUME_YES -eq 1 ]]; then
	sudo apt install -y rocm
else
	sudo apt install rocm
fi

echo "Adding user '$USER' to render/video groups"
sudo usermod -aG render,video "$USER"

if [[ $NO_REBOOT -eq 1 ]]; then
	echo "Installation finished. Please reboot manually to apply all settings."
	exit 0
fi

read -r -p "Reboot now? [y/N]: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
	sudo reboot
else
	echo "Skipped reboot. Reboot manually when ready."
fi