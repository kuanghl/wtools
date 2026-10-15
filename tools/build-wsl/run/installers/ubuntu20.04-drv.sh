#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run as root (sudo ./$(basename "$0"))"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  Ubuntu 20.04 Driver Build Dependencies Installer"
echo "============================================"

echo "[1/2] Installing offline DEB packages..."
cd "$SCRIPT_DIR/packages"
dpkg -i --force-depends *.deb || true
dpkg --configure -a || true

echo "[2/2] Verifying kernel headers..."
KVER=$(uname -r)
echo "Running kernel: $KVER"
if ls /usr/src/linux-headers-*${KVER}* -d 2>/dev/null; then
    echo "linux-headers matched"
else
    echo "WARNING: linux-headers version may not match running kernel."
    echo "Available: $(ls /usr/src/ | grep linux-headers || echo 'none')"
fi

echo ""
echo "=== Installation Complete ==="
