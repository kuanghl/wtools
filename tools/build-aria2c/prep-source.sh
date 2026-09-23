#!/usr/bin/env bash
# 下载 aria2 上游源码 + autoreconf -i + 打包为 aria2-src.tar.gz
# 注意：ARIA2_REF 是 aria2 上游源码的 ref，与本仓库 tag 无关
set -euo pipefail

ARIA2_REPO="${ARIA2_REPO:-https://github.com/aria2/aria2.git}"
ARIA2_REF="${ARIA2_REF:-release-1.37.0}"

# 归一去 refs/ 前缀（防止传入 refs/tags/xxx）
ARIA2_REF="${ARIA2_REF#refs/tags/}"
ARIA2_REF="${ARIA2_REF#refs/heads/}"

WORK_DIR="$(pwd)/.src-work"
rm -rf "$WORK_DIR" aria2-src.tar.gz
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "==> ARIA2_REF = $ARIA2_REF"

# 优先使用 codeload tarball
TARBALL_URL="https://github.com/aria2/aria2/archive/${ARIA2_REF}.tar.gz"
echo "==> Trying tarball: $TARBALL_URL"

if curl -fL --retry 3 --retry-delay 5 -o aria2.tar.gz "$TARBALL_URL"; then
  tar -xzf aria2.tar.gz
  EXTRACTED="$(find . -maxdepth 1 -type d -name 'aria2-*' ! -name 'aria2.tar.gz' | head -n1)"
  if [ -z "$EXTRACTED" ]; then
    echo "Error: extracted directory not found"; exit 1
  fi
  mv "$EXTRACTED" aria2
  cd aria2
else
  echo "==> Tarball failed, fallback to git clone"
  git clone --depth 1 --branch "$ARIA2_REF" "$ARIA2_REPO" aria2
  cd aria2
fi

# 生成 configure / Makefile.in
autoreconf -i

# 打包
cd ..
tar czf ../aria2-src.tar.gz aria2

echo "==> Done:"
ls -lh ../aria2-src.tar.gz