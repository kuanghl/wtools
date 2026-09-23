#!/usr/bin/env bash
set -euo pipefail

ARCH="${ARCH:-arm64}"
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

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

# macOS 使用原生 clang，不要用 gcc / gcc-ar / LTO
export CC=clang
export CXX=clang++
unset AR RANLIB NM || true
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS=""

OPENSSL_PREFIX="$(brew --prefix openssl@3)"
EXPAT_PREFIX="$(brew --prefix expat)"
CARES_PREFIX="$(brew --prefix c-ares)"

export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:$EXPAT_PREFIX/lib/pkgconfig:$CARES_PREFIX/lib/pkgconfig"
export CPPFLAGS="-I$OPENSSL_PREFIX/include -I$EXPAT_PREFIX/include -I$CARES_PREFIX/include"
export LDFLAGS="-L$OPENSSL_PREFIX/lib -L$EXPAT_PREFIX/lib -L$CARES_PREFIX/lib"

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

make -j"$(sysctl -n hw.ncpu)"

cp src/aria2c "$DIST_DIR/aria2c"
strip "$DIST_DIR/aria2c" 2>/dev/null || true

cd "$DIST_DIR"
tar czf "aria2-macos-${ARCH}.tar.gz" aria2c
rm -f aria2c

echo "==> Artifact:"
ls -lh "$DIST_DIR"