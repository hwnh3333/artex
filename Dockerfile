# syntax=docker/dockerfile:1
#
# 老魏二改 ARTEX 的 Linux 运行镜像（默认 linux/amd64）。
# 只装运行时需要的依赖；扫描器全部来自 redteam/toolkit/ 下的 Linux ELF，
# 不包含 Windows exe、Windows JDK、GUI 版冰蝎/哥斯拉/AntSword，也不装 hashcat/john。
#
# 构建：
#   docker buildx build --platform linux/amd64 --build-arg TARGETARCH=amd64 -t artex-oldwei:latest --load .
# 或：
#   ./build-image.sh amd64
#
# arm64：必须有 artex-arm64（老魏的 linux/arm64 主程序）。当前目录只有
#        artex-amd64，所以 build-image.sh arm64 会明确拒绝，而不是产出坏镜像。

FROM python:3.12-slim-bookworm

ARG TARGETARCH=amd64
ARG ARTEX_BIN=artex-${TARGETARCH}
ARG INSTALL_NETEXEC=0

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/state/home \
    XDG_CACHE_HOME=/state/cache \
    XDG_CONFIG_HOME=/state/home/.config \
    PIP_CACHE_DIR=/state/cache/pip \
    PYTHONUSERBASE=/state/python \
    PYTHONDONTWRITEBYTECODE=1 \
    TMPDIR=/state/tmp \
    ARTEX_CONFIG=/state/config.json \
    ARTEX_SKILL_DIR=/state/skills \
    ARTEX_KB_DIR=/state/redteam \
    PATH=/app/.venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

# 运行期依赖：
#   - nmap/curl/wget/git/jq/unzip：基础侦察与排障
#   - postgresql-client/sqlite3：知识库/数据库操作
#   - openjdk-17-jre-headless + apktool：jadx/cfr/apktool（无 X11）
#   - hydra/sshpass/proxychains4：在线弱口令与代理链（不装 hashcat/john）
#   - redis-tools/default-mysql-client：redis-cli/mysql
#   - tmux/ncat/socat：隧道与交互
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git jq unzip xz-utils \
      ripgrep file binutils procps \
      nmap postgresql-client sqlite3 \
      openjdk-17-jre-headless apktool \
      hydra proxychains4 sshpass \
      redis-tools default-mysql-client \
      tmux ncat socat \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 预编译好的 Linux 单二进制；按 TARGETARCH 选 artex-amd64 / artex-arm64。
COPY ${ARTEX_BIN} /app/artex
COPY start.sh /app/start.sh
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
COPY defaults.sql /app/defaults.sql
COPY config.example.json /app/config.example.json
COPY requirements.txt /app/requirements.txt
COPY README-linux.txt /app/README-linux.txt
COPY skills/ /app/skills/
COPY redteam/ /app/redteam/
# Release 资产里的 redteam/skills 仍是官方单模式旧版；用仓库内双模式版覆盖，
# 保证镜像内两份 fofa-recon 都是“默认官方、设 FOFA_POOL_BASE 才走号池”。
COPY skills/fofa-recon.md /app/redteam/skills/fofa-recon.md
COPY nuclei-templates/ /app/redteam/nuclei-templates/

# Python 工具装进镜像内 venv；不依赖运行时联网。
RUN chmod +x /app/artex /app/start.sh /app/docker-entrypoint.sh \
 && python3 -m venv /app/.venv \
 && /app/.venv/bin/python -m pip install --no-cache-dir --upgrade pip \
 && /app/.venv/bin/pip install --no-cache-dir -r /app/requirements.txt \
 && rm -f /app/.venv/bin/httpx \
 && if [ "$INSTALL_NETEXEC" = "1" ]; then \
      /app/.venv/bin/pip install --no-cache-dir \
        'git+https://github.com/Pennyw0rth/NetExec.git@v1.5.1' \
      || echo '[build] netexec 未装上，继续构建'; \
    fi \
 && mkdir -p /state/home /state/cache/pip /state/cache/npm /state/tmp \
             /state/data /state/skills /state/redteam

EXPOSE 8787 8788

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8787/api/health >/dev/null || exit 1

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["-addr", ":8787", "-proxy", ":8788"]
