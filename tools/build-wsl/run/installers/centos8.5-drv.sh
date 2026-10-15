#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run as root (sudo ./$(basename "$0"))"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  CentOS 8.5 Driver Build Dependencies Installer"
echo "============================================"

echo "[1/2] Installing offline RPM packages..."
rpm -Uvh --nodeps "$SCRIPT_DIR"/packages/*.rpm || true
rpm -Uvh --force "$SCRIPT_DIR"/packages/*.rpm || true

echo "[2/2] Verifying kernel modules..."
KVER=$(uname -r)
echo "Running kernel: $KVER"
if [ -d "/usr/src/kernels/${KVER}" ]; then
    echo "kernel-devel matched: /usr/src/kernels/${KVER}"
else
    echo "WARNING: kernel-devel version may not match running kernel."
    echo "Available: $(ls /usr/src/kernels/ 2>/dev/null || echo 'none')"
fi

echo ""
echo "=== Installation Complete ==="
