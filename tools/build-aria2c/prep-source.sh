#!/usr/bin/env bash
# 只执行一次：下载 aria2 源码 + autoreconf -i + 打包为 aria2-src.tar.gz
set -euo pipefail

ARIA2_REPO="${ARIA2_REPO:-https://github.com/aria2/aria2.git}"
ARIA2_REF="${ARIA2_REF:-master}"

WORK_DIR="$(pwd)/.src-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ================================================================
# 用 codeload tarball，不走完整 git clone
# 优点：体积更小（不含 .git）、下载更快、不受 --depth 限制
# ================================================================
# 归一化 ref：去掉可能存在的 refs/tags/ 前缀
REF="${ARIA2_REF#refs/tags/}"
REF="${REF#refs/heads/}"

TARBALL_URL="https://github.com/aria2/aria2/archive/${REF}.tar.gz"
echo "==> Downloading $TARBALL_URL"

if ! curl -fL --retry 3 --retry-delay 5 -o aria2.tar.gz "$TARBALL_URL"; then
  echo "==> tarball not found, fallback to git clone"
  git clone --depth 1 --branch "$ARIA2_REF" "$ARIA2_REPO" aria2
  cd aria2
else
  tar -xzf aria2.tar.gz
  # codeload 解压后的目录名形如 aria2-<ref>
  EXTRACTED="$(find . -maxdepth 1 -type d -name 'aria2-*' | head -n1)"
  mv "$EXTRACTED" aria2
  cd aria2
fi

# ================================================================
# autoreconf：生成 configure / Makefile.in
# 这一步在各平台重复执行完全等价，所以只做一次
# ================================================================
autoreconf -i

# ================================================================
# 打包回上层目录，供 upload-artifact 使用
# ================================================================
cd ..
tar czf ../aria2-src.tar.gz aria2

echo "==> Done:"
ls -lh ../aria2-src.tar.gz