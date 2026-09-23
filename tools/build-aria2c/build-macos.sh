#!/usr/bin/env bash
# 构建 macOS aria2c（在 macos-13 / macos-14 原生 runner 上执行）
# 说明：
#   - macOS 上系统 gcc 实为 clang 的别名，必须显式指定 clang / clang++
#   - 不使用 GCC 的 LTO（-flto=auto）和 gcc-ar/gcc-ranlib/gcc-nm
#     这些工具在 macOS + Homebrew 环境下会与 Apple 工具链冲突，
#     导致 configure 阶段 "C compiler cannot create executables"
#   - 完全静态链接在 macOS 上不可行，因此不添加 -static
set -euo pipefail

ARCH="${ARCH:-arm64}"
RELEASE_TAG="${RELEASE_TAG:-${ARIA2_REF:-dev}}"
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
# 2. 基础编译环境
# ================================================================
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

# 显式使用 clang —— 不要设置成 gcc，因为 macOS 上 /usr/bin/gcc
# 是 Apple Clang 的 symlink，但某些 autoconf 检查在混用
# GCC 参数（如 -flto=auto -ffat-lto-objects）时会失败
export CC=clang
export CXX=clang++
unset AR RANLIB NM || true   # 让 configure 使用系统默认 ar/ranlib/nm

# 不启用 LTO，macOS 上的 clang LTO 与 gcc-ar 路径不兼容
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS=""

# ================================================================
# 3. Homebrew 依赖路径
# ================================================================
OPENSSL_PREFIX="$(brew --prefix openssl@3)"
EXPAT_PREFIX="$(brew --prefix expat)"
CARES_PREFIX="$(brew --prefix c-ares)"

echo "==> OpenSSL prefix: $OPENSSL_PREFIX"
echo "==> Expat   prefix: $EXPAT_PREFIX"
echo "==> c-ares  prefix: $CARES_PREFIX"

export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:$EXPAT_PREFIX/lib/pkgconfig:$CARES_PREFIX/lib/pkgconfig"
export CPPFLAGS="-I$OPENSSL_PREFIX/include -I$EXPAT_PREFIX/include -I$CARES_PREFIX/include"
export LDFLAGS="-L$OPENSSL_PREFIX/lib -L$EXPAT_PREFIX/lib -L$CARES_PREFIX/lib"

# ================================================================
# 4. 配置 aria2
#    - 使用 Homebrew 的 OpenSSL / Expat / c-ares
#    - 不启用 sqlite3 / libxml2 / libssh2，减少依赖
#    - ARIA2_STATIC=yes 只影响 aria2 自身对象，不强制系统库静态
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
make -j"$(sysctl -n hw.ncpu)"

# ================================================================
# 6. strip + 打包
# ================================================================
cp src/aria2c "$DIST_DIR/aria2c"
strip "$DIST_DIR/aria2c" 2>/dev/null || true

cd "$DIST_DIR"
tar czf "aria2-macos-${ARCH}.tar.gz" aria2c
rm -f aria2c

echo "==> Artifact:"
ls -lh "$DIST_DIR"