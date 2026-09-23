#!/usr/bin/env bash
# 在 MSYS2 MINGW64 shell 中执行
set -euo pipefail

ARIA2_REF="${ARIA2_REF:-master}"
BUILD_DIR="$(pwd)/build"
DIST_DIR="$(pwd)/dist"
SRC_TARBALL="$(pwd)/aria2-src.tar.gz"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

if [ ! -f "$SRC_TARBALL" ]; then
  echo "Error: $SRC_TARBALL not found. Did prep-source job run?"
  exit 1
fi
tar -xzf "$SRC_TARBALL" -C "$BUILD_DIR"
cd "$BUILD_DIR/aria2"

# ================================================================
# LTO + 完全静态链接
# ================================================================
export CC=gcc
export CXX=g++
export AR=gcc-ar
export RANLIB=gcc-ranlib
export NM=gcc-nm
export CFLAGS="-O2 -flto=auto -ffat-lto-objects"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-flto=auto -static -static-libgcc -static-libstdc++"

ARIA2_STATIC=yes ./configure \
  --without-gnutls \
  --with-openssl \
  --with-libexpat \
  --without-libxml2 \
  --without-sqlite3 \
  --with-libcares \
  --without-libssh2 \
  --disable-nls \
  --disable-sftp \
  --disable-websocket

make -j"$(nproc)"

cp src/aria2c.exe "$DIST_DIR/aria2c.exe"
strip "$DIST_DIR/aria2c.exe" 2>/dev/null || true

cd "$DIST_DIR"
zip -9 "aria2-${ARIA2_REF}-windows-x86_64.zip" aria2c.exe
rm -f aria2c.exe

echo "==> Artifact:"
ls -lh "$DIST_DIR"