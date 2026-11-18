#!/usr/bin/env bash
# 把 Docker 构建需要的大文件打成一个 GitHub Release 资产（方案 A）。
# 输出默认放在包目录的上一级，避免被 .dockerignore / git 收进去。
# 用法：./pack-redteam-assets.sh [输出路径]
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-../artex-redteam-assets.tar.gz}"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

echo "[pack] 输出：$OUT"
rm -f "$OUT" "$OUT.sha256"

tar -czf "$OUT" \
  --exclude='redteam/.env' \
  --exclude='redteam/INSTALL-NOTES.md' \
  --exclude='redteam/restore-tools.sh' \
  --exclude='redteam/patches' \
  --exclude='redteam/runs' \
  --exclude='redteam/*.bak-*' \
  --exclude='redteam/toolkit/runs' \
  --exclude='redteam/toolkit/vps/id_rsa*' \
  --exclude='redteam/toolkit/vps/rt-tunnel-key*' \
  --exclude='nuclei-templates/.git' \
  artex-amd64 redteam nuclei-templates

sha256sum "$OUT" | tee "$OUT.sha256"
echo
echo "[pack] 下一步："
echo "  1) 在 GitHub 建 Release（例如 tag assets-20261118）"
echo "  2) 上传：$(basename "$OUT")"
echo "  3) 把 .github/workflows/build-docker.yml 里的 ASSET_SHA256 改成："
echo "     $(cut -d' ' -f1 "$OUT.sha256")"
