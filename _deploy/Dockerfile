# 在 GHCR 老魏镜像之上补装运行时依赖，不改宿主机。
# 基础镜像已带：nmap/hydra/sshpass/proxychains4/tmux/ncat/socat/psql/sqlite3/
# openjdk-17/apktool/impacket/sqlmap/dirsearch/pypykatz，以及 redteam/toolkit 里的
# fscan/gogo/subfinder/dnsx/httpx/katana/naabu/ksubdomain/chisel/frp/suo5/
# nuclei/ffuf/gospider/massdns/jadx/cfr。
#
# 这里补的是 install-deps.sh / Dockerfile 默认没装的部分：
#   1. NetExec（base 镜像 INSTALL_NETEXEC 默认 0；且 v1.5.1 直接装会因 certipy 包名冲突失败）
#   2. 去掉 VPS 中转工具与专用技能（不使用 VPS 那一套）
FROM ghcr.io/hwnh3333/artex:latest

# FOFA 双模式技能：默认官方 API，设置 FOFA_POOL_BASE 才切第三方号池。
# 覆盖镜像内三份副本，避免旧 loader 回退到官方单模式版本。
COPY fofa-recon/SKILL.md /app/skills/fofa-recon/SKILL.md
COPY fofa-recon/SKILL.md /app/skills/fofa-recon.md
COPY fofa-recon/SKILL.md /app/redteam/skills/fofa-recon.md

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# NetExec 装进独立 venv：避免它把 /app/.venv 里的 dirsearch/sqlmap 依赖降级。
# 先 --no-deps 装本体，再补依赖；certipy-ad 用 PyPI 5.0.4 替代 git 版，
# 绕开 v1.5.1 中 certipy-ad/certipy-nxc 元数据名冲突。
RUN python3 -m venv /opt/netexec \
 && /opt/netexec/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/netexec/bin/pip install --no-cache-dir --no-deps \
      "git+https://github.com/Pennyw0rth/NetExec.git@v1.5.1" \
 && /opt/netexec/bin/pip install --no-cache-dir \
      "aardwolf>=0.2.8" \
      "argcomplete>=3.1.4" \
      "asyauth>=0.0.20" \
      "beautifulsoup4>=4.11,<5" \
      "bloodhound-ce>=1.8.0" \
      "dploot>=3.1.0" \
      "dsinternals>=1.2.4" \
      "jwt>=1.3.1" \
      "lsassy>=3.1.11" \
      "masky>=0.2.1" \
      "minikerberos>=0.4.1" \
      "neo4j>=5.0.0" \
      "paramiko>=3.3.1" \
      "pefile>=2024.8.26,<2025" \
      "pyasn1-modules>=0.3.0" \
      "pylnk3>=0.4.3" \
      "pypsrp>=0.8.1" \
      "pypykatz>=0.6.8" \
      "python-dateutil>=2.8.2" \
      "python-libnmap>=0.7.3" \
      "requests>=2.27.1" \
      "rich>=13.3.5" \
      "sqlalchemy>=2.0.4" \
      "termcolor>=2.4.0" \
      "terminaltables>=3.1.0" \
      "xmltodict>=0.13.0" \
      "impacket==0.13.1" \
      "oscrypto>=1.3.0" \
      "certipy-ad==5.0.4" \
 && ln -sf /opt/netexec/bin/nxc /usr/local/bin/nxc \
 && ln -sf /opt/netexec/bin/netexec /usr/local/bin/netexec \
 && ln -sf /opt/netexec/bin/nxcdb /usr/local/bin/nxcdb

# 移除 VPS 中转工具/说明（其中含真实 VPS 地址）和专用技能。
# 其他技能里少量“用 vps.sh 分发载荷”的备选步骤会失效，但 fscan/gogo 等工具本身可用。
RUN rm -rf /app/redteam/toolkit/vps \
 && rm -rf /app/skills/vps-reverse-shell \
 && rm -f /app/skills/vps-reverse-shell.md \
          /app/redteam/skills/vps-reverse-shell.md

# 让镜像内自检时也能直接执行；运行时 entrypoint 还会再补一次。
RUN chmod +x \
      /app/redteam/toolkit/nuclei/nuclei \
      /app/redteam/toolkit/fscan/fscan \
      /app/redteam/toolkit/gogo/gogo \
      /app/redteam/toolkit/subfinder/subfinder \
      /app/redteam/toolkit/dnsx/dnsx \
      /app/redteam/toolkit/httpx/httpx \
      /app/redteam/toolkit/katana/katana \
      /app/redteam/toolkit/naabu/naabu \
      /app/redteam/toolkit/ksubdomain/ksubdomain \
      /app/redteam/toolkit/chisel/chisel \
      /app/redteam/toolkit/frp/frpc \
      /app/redteam/toolkit/frp/frps \
      /app/redteam/toolkit/suo5/suo5-linux-amd64 \
      /app/redteam/toolkit/ffuf/ffuf \
      /app/redteam/toolkit/gospider/gospider \
      /app/redteam/toolkit/massdns/massdns \
      /app/redteam/toolkit/jadx/bin/jadx

WORKDIR /app
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["-addr", ":8787", "-proxy", ":8788"]
