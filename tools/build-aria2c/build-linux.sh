#!/usr/bin/env bash
set -euo pipefail

ARCH="${ARCH:-x86_64}"
# 注意：产物用 RELEASE_TAG 命名，不是 ARIA2_REF
RELEASE_TAG="${RELEASE_TAG:-${ARIA2_REF:-dev}}"
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

# LTO（借鉴 Rorschach331）
export CC=gcc
export CXX=g++
export AR=gcc-ar
export RANLIB=gcc-ranlib
export NM=gcc-nm
export CFLAGS="-O2 -fPIC -flto=auto -ffat-lto-objects"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-flto=auto"

ARIA2_STATIC=yes ./configure \
  --without-gnutls \
  --with-openssl \
  --with-libexpat \
  --without-libxml2 \
  --with-sqlite3 \
  --with-libcares \
  --without-libssh2 \
  --disable-nls \
  --disable-sftp \
  --disable-websocket \
  --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt

make -j"$(nproc)"

cp src/aria2c "$DIST_DIR/aria2c"
strip "$DIST_DIR/aria2c" 2>/dev/null || true

cd "$DIST_DIR"
tar czf "aria2-linux-${ARCH}.tar.gz" aria2c
rm -f aria2c

echo "==> Artifact:"
ls -lh "$DIST_DIR"