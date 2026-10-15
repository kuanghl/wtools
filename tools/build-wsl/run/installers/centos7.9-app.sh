#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run as root (sudo ./$(basename "$0"))"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  CentOS 7.9 App Build Dependencies Installer"
echo "============================================"

echo "[1/2] Installing offline RPM packages..."
rpm -Uvh --nodeps "$SCRIPT_DIR"/packages/*.rpm || true
rpm -Uvh --force "$SCRIPT_DIR"/packages/*.rpm || true

echo "[2/2] Configuring devtoolset-9..."
echo "source /opt/rh/devtoolset-9/enable" >> /etc/bashrc

echo ""
echo "=== Installation Complete ==="
bash -lc "gcc --version | head -1"
echo "devtoolset-9 enabled in /etc/bashrc (new sessions auto-activate)"
echo "For current session: source /opt/rh/devtoolset-9/enable"
