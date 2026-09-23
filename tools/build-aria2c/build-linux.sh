#!/usr/bin/env bash
# 构建 Linux aria2c（使用 prep-source 准备好的源码）
set -euo pipefail

ARCH="${ARCH:-x86_64}"
ARIA2_REF="${ARIA2_REF:-master}"
BUILD_DIR="$(pwd)/build"
DIST_DIR="$(pwd)/dist"
SRC_TARBALL="$(pwd)/aria2-src.tar.gz"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ================================================================
# 解压预先准备好的源码
# ================================================================
if [ ! -f "$SRC_TARBALL" ]; then
  echo "Error: $SRC_TARBALL not found. Did prep-source job run?"
  exit 1
fi
tar -xzf "$SRC_TARBALL" -C "$BUILD_DIR"
cd "$BUILD_DIR/aria2"

# ================================================================
# LTO 配置（借鉴 Rorschach331）
# ================================================================
export CC=gcc
export CXX=g++
export AR=gcc-ar
export RANLIB=gcc-ranlib
export NM=gcc-nm
export CFLAGS="-O2 -fPIC -flto=auto -ffat-lto-objects"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-flto=auto"

# ================================================================
# 修复 libc-ares 静态库命名问题
# ================================================================
case "$ARCH" in
  x86_64)
    CARES_DIR="/usr/lib/x86_64-linux-gnu"
    ;;
  aarch64)
    CARES_DIR="/usr/lib/aarch64-linux-gnu"
    ;;
  *)
    CARES_DIR="/usr/lib/$(uname -m)-linux-gnu"
    ;;
esac

if [ -f "$CARES_DIR/libcares_static.a" ] && [ ! -e "$CARES_DIR/libcares.a" ]; then
  echo "==> Creating symlink: $CARES_DIR/libcares.a -> libcares_static.a"
  sudo ln -s "$CARES_DIR/libcares_static.a" "$CARES_DIR/libcares.a"
fi

# ================================================================
# 配置 + 编译
# ================================================================
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

# ================================================================
# strip + 打包
# ================================================================
cp src/aria2c "$DIST_DIR/aria2c"
strip "$DIST_DIR/aria2c" 2>/dev/null || true

cd "$DIST_DIR"
tar czf "aria2-${ARIA2_REF}-linux-${ARCH}.tar.gz" aria2c
rm -f aria2c

echo "==> Artifact:"
ls -lh "$DIST_DIR"