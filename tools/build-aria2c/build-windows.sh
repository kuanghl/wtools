#!/usr/bin/env bash
# 构建 Windows aria2c（在 MSYS2 MINGW64 shell 中执行）
# 保留 Rorschach331 的 LTO 经验
set -euo pipefail

ARIA2_REPO="${ARIA2_REPO:-https://github.com/aria2/aria2.git}"
ARIA2_REF="${ARIA2_REF:-master}"
BUILD_DIR="$(pwd)/build"
DIST_DIR="$(pwd)/dist"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ================================================================
# MSYS2 MINGW64 环境下 gcc 本身就是 x86_64-w64-mingw32 交叉编译器，
# 只是以"原生"方式暴露出来，工具链名字不带前缀。
# ================================================================
export CC=gcc
export CXX=g++
export AR=gcc-ar
export RANLIB=gcc-ranlib
export NM=gcc-nm

# LTO + 完全静态链接
export CFLAGS="-O2 -flto=auto -ffat-lto-objects"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-flto=auto -static -static-libgcc -static-libstdc++"

# ================================================================
# 编译 aria2
# ================================================================
git clone --depth 1 --branch "$ARIA2_REF" "$ARIA2_REPO" "$BUILD_DIR/aria2"
cd "$BUILD_DIR/aria2"
autoreconf -i

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

# ================================================================
# strip + 打包
# ================================================================
cp src/aria2c.exe "$DIST_DIR/aria2c.exe"
strip "$DIST_DIR/aria2c.exe" 2>/dev/null || true

cd "$DIST_DIR"
# MSYS2 自带 zip
zip -9 "aria2-${ARIA2_REF}-windows-x86_64.zip" aria2c.exe
rm -f aria2c.exe

echo "==> Artifact:"
ls -lh "$DIST_DIR"