#!/usr/bin/env bash
# ARTEX Linux 依赖安装：系统包 + PostgreSQL 初始化 + Python 工具 + config.json
set -euo pipefail
cd "$(dirname "$0")"
say() { printf "\n==> %s\n" "$*"; }
die() { printf "\n!! %s\n" "$*" >&2; exit 1; }
# root 直接跑时 $SUDO 为空，`$SUDO -u postgres psql` 会展开成 `-u postgres psql` 而报
# "command not found"。统一走 as_pg，root / 非 root 都能用。
as_pg() {
  if [ "$(id -u)" -eq 0 ]; then runuser -u postgres -- "$@"; else sudo -u postgres -- "$@"; fi
}

[ "$(uname -s)" = "Linux" ] || die "这个脚本只适用于 Linux"

# 架构自检：一份脚本给 amd64 / arm64 两个包共用，不能写死 x86_64。
# 用包内 artex 的真实架构与本机 uname -m 对照，发错包就当场报出来。
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)        WANT="x86-64" ;;
  aarch64|arm64) WANT="aarch64" ;;
  *)             die "不支持的 CPU 架构：$ARCH（本包只提供 amd64 / arm64）" ;;
esac
if [ -f artex ]; then
  GOT="$(file -b artex 2>/dev/null || echo unknown)"
  case "$GOT" in
    *"$WANT"*) : ;;
    *) die "包内 artex 架构是 [$GOT]，与本机 $ARCH 不匹配——请换成对应架构的包" ;;
  esac
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

say "安装系统依赖（PostgreSQL / Nmap / JDK / Python / 基础工具）"
if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq postgresql postgresql-contrib nmap openjdk-21-jdk \
    python3 python3-venv python3-pip curl unzip ca-certificates git
elif command -v dnf >/dev/null 2>&1; then
  $SUDO dnf install -y postgresql-server nmap java-21-openjdk python3 python3-pip curl unzip
  $SUDO postgresql-setup --initdb || true
elif command -v yum >/dev/null 2>&1; then
  $SUDO yum install -y postgresql-server nmap java-21-openjdk python3 python3-pip curl unzip
  $SUDO postgresql-setup initdb || true
else
  die "未识别的包管理器（需要 apt-get / dnf / yum）"
fi

say "启动 PostgreSQL"
if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl enable --now postgresql || $SUDO systemctl enable --now postgresql-17 || true
else
  $SUDO service postgresql start || true
fi
for i in $(seq 1 30); do pg_isready -h 127.0.0.1 -q && break; sleep 1; done

say "初始化数据库 artex"
PGPASS_FILE=.pgpass.generated
if [ ! -f "$PGPASS_FILE" ]; then
  head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20 > "$PGPASS_FILE"
  chmod 600 "$PGPASS_FILE"
fi
PGPASS="$(cat "$PGPASS_FILE")"
as_pg psql -v ON_ERROR_STOP=1 -q \
  -c "ALTER USER postgres PASSWORD '$PGPASS';" \
  -c "SELECT 'CREATE DATABASE artex' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='artex')\gexec" \
  >/dev/null || true
# 破甲模式默认开关不在这里预置：此刻 settings 表还没建（由 ARTEX 首次启动迁移创建），
# 插入必然失败。真正的默认（破甲开关 + 预设 + 拦截规则）由 start-artex.sh 在面板就绪后
# 一次性应用 defaults.sql 完成。
printf "    数据库 artex 就绪（密码见 %s）\n" "$PGPASS_FILE"
printf "    破甲默认配置将在首次启动后自动应用\n"

say "安装 Python 工具（impacket / netexec / pypykatz / sqlmap）"
python3 -m venv .venv
./.venv/bin/python -m pip install --upgrade pip >/dev/null
# netexec 不在 PyPI（官方只发 GitHub），写进 requirements.txt 会让 pip 直接失败并中断
# 整个安装（set -e）。这里先装能装的，再从仓库补，装不上只告警不阻断。
./.venv/bin/pip install -r requirements.txt
./.venv/bin/pip install 'git+https://github.com/Pennyw0rth/NetExec.git@v1.5.1' >/dev/null 2>&1 \
  || printf "    !! netexec 未装上（GitHub 不通？稍后手动补：\n       ./.venv/bin/pip install git+https://github.com/Pennyw0rth/NetExec.git）\n"

say "生成 config.json"
if [ -f config.json ]; then
  printf "    config.json 已存在，保留不动\n"
else
  cat > config.json <<JSON
{
  "database": {
    "host": "127.0.0.1",
    "port": 5432,
    "user": "postgres",
    "password": "$PGPASS",
    "dbname": "artex",
    "sslmode": "disable"
  },
  "knowledge_dir": "$(pwd)/redteam"
}
JSON
  chmod 600 config.json
  printf "    config.json 已生成\n"
fi

chmod +x artex start.sh start-artex.sh 2>/dev/null || true

say "检查 nuclei"
if command -v nuclei >/dev/null 2>&1; then
  nuclei -update-templates >/dev/null 2>&1 || true
  printf "    nuclei 已就绪\n"
else
  cat <<EOF
    未安装 nuclei。需要时执行：
      curl -L https://github.com/projectdiscovery/nuclei/releases/latest/download/nuclei_3.x_linux_amd64.zip -o /tmp/nuclei.zip
      （版本号以 Releases 页为准）解压后放进 /usr/local/bin
EOF
fi

say "完成"
cat <<EOF
下一步：
  1. 启动：./start-artex.sh
  2. 浏览器打开 http://127.0.0.1:8787 ，首次进 /setup 设置登录密码
  3. 到「API KEY 配置」填模型 Key

说明：
  - start-artex.sh 会导出 DSH_HOME / ARTEX_HOME / ARTEX_KB_DIR，并把 .venv 加进 PATH
  - redteam/toolkit 里带的是 Linux 版扫描器（fscan/gogo/subfinder/dnsx/httpx/katana/naabu/chisel/frp/suo5）
  - 冰蝎/哥斯拉是 Java jar，装了 JDK 后可直接跑
EOF
