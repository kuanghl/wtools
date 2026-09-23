#!/usr/bin/env bash
# 构建 Windows aria2c（在 MSYS2 MINGW64 shell 中执行）
set -euo pipefail

ARIA2_REF="${ARIA2_REF:-master}"
BUILD_DIR="$(pwd)/build"
DIST_DIR="$(pwd)/dist"
SRC_TARBALL="$(pwd)/aria2-src.tar.gz"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ================================================================
# 1. 校验并解压 prep-source 阶段准备好的源码
# ================================================================
if [ ! -f "$SRC_TARBALL" ]; then
  echo "Error: $SRC_TARBALL not found. Did the prep-source job run?"
  exit 1
fi
tar -xzf "$SRC_TARBALL" -C "$BUILD_DIR"
cd "$BUILD_DIR/aria2"

# ================================================================
# 2. 工具链（MSYS2 MINGW64 下 gcc 本身即 x86_64-w64-mingw32 交叉编译器）
# ================================================================
export CC=gcc
export CXX=g++
export AR=gcc-ar
export RANLIB=gcc-ranlib
export NM=gcc-nm

# ================================================================
# 3. 编译与链接配置
#    - LTO 和完全静态链接
#    - 显式定义 CARES_STATICLIB 修复 c-ares 静态链接
# ================================================================
export CFLAGS="-O2 -flto=auto -ffat-lto-objects -DCARES_STATICLIB"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-flto=auto -static -static-libgcc -static-libstdc++"

# 关键：确保 pkg-config 在链接时输出静态库标志
export PKG_CONFIG="pkg-config --static"

# ================================================================
# 4. 配置 aria2
# ================================================================
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

# ================================================================
# 5. 编译
# ================================================================
make -j"$(nproc)"

# ================================================================
# 6. strip + 打包
# ================================================================
cp src/aria2c.exe "$DIST_DIR/aria2c.exe"
strip "$DIST_DIR/aria2c.exe" 2>/dev/null || true

cd "$DIST_DIR"
zip -9 "aria2-${ARIA2_REF}-windows-x86_64.zip" aria2c.exe
rm -f aria2c.exe

echo "==> Artifact:"
ls -lh "$DIST_DIR"