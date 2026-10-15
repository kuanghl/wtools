#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run as root (sudo ./$(basename "$0"))"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  Ubuntu 20.04 App Build Dependencies Installer"
echo "============================================"

echo "[1/2] Installing offline DEB packages..."
cd "$SCRIPT_DIR/packages"
dpkg -i --force-depends *.deb || true
dpkg --configure -a || true

echo "[2/2] Verifying toolchain..."
gcc --version | head -1
cmake --version | head -1

echo ""
echo "=== Installation Complete ==="
