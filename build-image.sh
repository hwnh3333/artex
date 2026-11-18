#!/usr/bin/env bash
# 构建老魏二改 ARTEX 的 Linux 镜像。
# 用法：
#   ./build-image.sh             # linux/amd64
#   ./build-image.sh amd64
#   ./build-image.sh arm64       # 需要 artex-arm64 存在
#   INSTALL_NETEXEC=0 ./build-image.sh amd64
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${1:-amd64}"
case "$ARCH" in
  amd64|arm64) ;;
  *) echo "只支持 amd64 / arm64，收到：$ARCH" >&2; exit 2 ;;
esac

BIN="artex-$ARCH"
if [ ! -f "$BIN" ]; then
  cat >&2 <<EOF
缺少主程序 $BIN。
当前目录只有：
$(ls -1 artex-* 2>/dev/null || echo '  （没有 artex-*）')
老魏目前只提供了 linux/amd64 包；arm64 需要先把老魏的 artex-arm64 放到本目录。
EOF
  exit 1
fi

IMAGE="${ARTEX_IMAGE:-artex-oldwei}"
TAG="${ARTEX_TAG:-$ARCH}"
INSTALL_NETEXEC="${INSTALL_NETEXEC:-1}"

echo "[build] linux/$ARCH -> $IMAGE:$TAG (INSTALL_NETEXEC=$INSTALL_NETEXEC)"
docker buildx build \
  --platform "linux/$ARCH" \
  --build-arg "TARGETARCH=$ARCH" \
  --build-arg "ARTEX_BIN=artex-$ARCH" \
  --build-arg "INSTALL_NETEXEC=$INSTALL_NETEXEC" \
  -t "$IMAGE:$TAG" \
  --load \
  .
docker tag "$IMAGE:$TAG" "$IMAGE:latest" 2>/dev/null || true
echo "[build] 完成：$IMAGE:$TAG（并打上 :latest，方便 docker compose 直接启动）"
