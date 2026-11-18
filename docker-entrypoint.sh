#!/bin/sh
# 老魏二改 ARTEX 的 Docker 入口。
# 职责：
#   1. 建 /state 目录结构
#   2. 把镜像内置的 52 个技能播种到 /state/skills（缺哪个补哪个，不覆盖已有）
#   3. 把 redteam/ 资源播种到 /state/redteam（knowledge.db / pocs / toolkit / 模板）
#   4. 修 HOME 下的兼容软链、/usr/local/bin 工具软链、nuclei 模板配置
#   5. 后台等待数据库就绪，应用一次 defaults.sql 与 visibility.sql
#   6. 交给 start.sh 守护启动 artex
set -u

STATE="${ARTEX_STATE_DIR:-/state}"
HOME="${HOME:-$STATE/home}"
export HOME

mkdir -p "$STATE"/home "$STATE"/cache/pip "$STATE"/cache/npm "$STATE"/tmp \
         "$STATE"/data "$STATE"/skills "$STATE"/redteam 2>/dev/null || true

log() { printf '[entrypoint] %s\n' "$*"; }

# ── 1. 技能播种 ────────────────────────────────────────────────────────────
if [ -d /app/skills ] && [ -d "$STATE/skills" ]; then
  for src in /app/skills/*/; do
    [ -d "$src" ] || continue
    name=$(basename "$src")
    [ -e "$STATE/skills/$name" ] && continue
    cp -a "$src" "$STATE/skills/$name" 2>/dev/null \
      || log "技能 $name 播种失败（不影响启动）"
  done
fi

# ── 2. redteam 资源播种 ─────────────────────────────────────────────────────
if [ -d /app/redteam ]; then
  if [ ! -d "$STATE/redteam" ]; then
    cp -a /app/redteam "$STATE/redteam" 2>/dev/null || log "redteam 初始播种失败"
  else
    # 新版本新增的顶层条目补进去；已有 knowledge.db / .env 不覆盖。
    for src in /app/redteam/*; do
      [ -e "$src" ] || continue
      name=$(basename "$src")
      [ -e "$STATE/redteam/$name" ] && continue
      cp -a "$src" "$STATE/redteam/$name" 2>/dev/null || true
    done
    # pocs / toolkit / 模板：只补缺失文件，不覆盖用户改过的文件。
    for d in pocs toolkit nuclei-templates; do
      [ -d "/app/redteam/$d" ] || continue
      [ -d "$STATE/redteam/$d" ] || { cp -a "/app/redteam/$d" "$STATE/redteam/$d" 2>/dev/null || true; continue; }
      cp -an "/app/redteam/$d/." "$STATE/redteam/$d/" 2>/dev/null || true
    done
  fi
fi

# 可执行位：Windows 解压/复制常常丢，启动时补一次。
for t in \
  "$STATE/redteam/toolkit/fscan/fscan" \
  "$STATE/redteam/toolkit/fscan/fscan_linux_arm64" \
  "$STATE/redteam/toolkit/gogo/gogo" \
  "$STATE/redteam/toolkit/gogo/gogo_linux_arm64" \
  "$STATE/redteam/toolkit/subfinder/subfinder" \
  "$STATE/redteam/toolkit/dnsx/dnsx" \
  "$STATE/redteam/toolkit/httpx/httpx" \
  "$STATE/redteam/toolkit/katana/katana" \
  "$STATE/redteam/toolkit/naabu/naabu" \
  "$STATE/redteam/toolkit/ksubdomain/ksubdomain" \
  "$STATE/redteam/toolkit/chisel/chisel" \
  "$STATE/redteam/toolkit/frp/frpc" \
  "$STATE/redteam/toolkit/frp/frps" \
  "$STATE/redteam/toolkit/suo5/suo5-linux-amd64" \
  "$STATE/redteam/toolkit/nuclei/nuclei" \
  "$STATE/redteam/toolkit/ffuf/ffuf" \
  "$STATE/redteam/toolkit/gospider/gospider" \
  "$STATE/redteam/toolkit/massdns/massdns" \
  "$STATE/redteam/toolkit/jadx/bin/jadx"; do
  [ -f "$t" ] && chmod +x "$t" 2>/dev/null || true
done

# ── 3. JWT 固定到 /state（容器重建后登录态不失效）────────────────────────────
rm -f /app/jwt.key 2>/dev/null || true
ln -sf "$STATE/jwt.key" /app/jwt.key 2>/dev/null || true

# ── 4. HOME 兼容路径 ────────────────────────────────────────────────────────
mkdir -p "$HOME/.dsh" "$HOME/.local/bin" "$HOME/.local/share" "$HOME/.config/nuclei" 2>/dev/null || true
ln -sfn "$STATE/redteam" "$HOME/.dsh/redteam" 2>/dev/null || true
ln -sfn "$STATE/redteam/nuclei-templates" "$HOME/.local/nuclei-templates" 2>/dev/null || true
ln -sfn /usr/local/bin/httpx "$HOME/.local/bin/pd-httpx" 2>/dev/null || true
mkdir -p "$HOME/.proxychains" 2>/dev/null || true
[ -f /etc/proxychains4.conf ] && ln -sfn /etc/proxychains4.conf "$HOME/.proxychains/proxychains.conf" 2>/dev/null || true

# nuclei 模板路径写进配置；只在不存在时创建，避免覆盖用户配置。
if [ ! -f "$HOME/.config/nuclei/config.yaml" ]; then
  cat > "$HOME/.config/nuclei/config.yaml" <<'NUCLEI_EOF'
templates:
  - /state/redteam/nuclei-templates
NUCLEI_EOF
fi

# ── 5. /usr/local/bin 工具软链 ─────────────────────────────────────────────
link_tool() {
  name="$1"; target="$2"
  [ -f "$target" ] || return 0
  ln -sf "$target" "/usr/local/bin/$name" 2>/dev/null || true
}
link_tool fscan   "$STATE/redteam/toolkit/fscan/fscan"
link_tool gogo    "$STATE/redteam/toolkit/gogo/gogo"
link_tool subfinder "$STATE/redteam/toolkit/subfinder/subfinder"
link_tool dnsx    "$STATE/redteam/toolkit/dnsx/dnsx"
link_tool httpx   "$STATE/redteam/toolkit/httpx/httpx"
link_tool pd-httpx "$STATE/redteam/toolkit/httpx/httpx"
link_tool katana  "$STATE/redteam/toolkit/katana/katana"
link_tool naabu   "$STATE/redteam/toolkit/naabu/naabu"
link_tool ksubdomain "$STATE/redteam/toolkit/ksubdomain/ksubdomain"
link_tool chisel  "$STATE/redteam/toolkit/chisel/chisel"
link_tool frpc    "$STATE/redteam/toolkit/frp/frpc"
link_tool frps    "$STATE/redteam/toolkit/frp/frps"
link_tool suo5    "$STATE/redteam/toolkit/suo5/suo5-linux-amd64"
link_tool nuclei  "$STATE/redteam/toolkit/nuclei/nuclei"
link_tool ffuf    "$STATE/redteam/toolkit/ffuf/ffuf"
link_tool gospider "$STATE/redteam/toolkit/gospider/gospider"
link_tool massdns "$STATE/redteam/toolkit/massdns/massdns"
link_tool jadx    "$STATE/redteam/toolkit/jadx/bin/jadx"
# impacket 的脚本名是 xxx.py；补 impacket-xxx 别名，方便技能直接调用。
for s in /app/.venv/bin/*.py; do
  [ -x "$s" ] || continue
  base=$(basename "$s" .py)
  ln -sf "$s" "/usr/local/bin/impacket-$base" 2>/dev/null || true
done
# cfr 需要 java -jar，包一层脚本。
if [ -f "$STATE/redteam/toolkit/decompilers/cfr.jar" ]; then
  cat > /usr/local/bin/cfr <<'CFR_EOF'
#!/bin/sh
exec java -jar /state/redteam/toolkit/decompilers/cfr.jar "$@"
CFR_EOF
  chmod +x /usr/local/bin/cfr 2>/dev/null || true
fi

# ── 6. 首次启动应用 defaults.sql / visibility.sql ───────────────────────────
if [ "${APPLY_DEFAULTS:-1}" = "1" ] && [ -n "${PGPASSWORD:-${POSTGRES_PASSWORD:-}}" ]; then
  (
    export PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"
    export PGHOST="${PGHOST:-postgres}"
    export PGPORT="${PGPORT:-5432}"
    export PGUSER="${PGUSER:-artex}"
    export PGDATABASE="${PGDATABASE:-artex}"

    for i in $(seq 1 90); do
      if psql -Atqc "SELECT to_regclass('public.settings') IS NOT NULL" 2>/dev/null | grep -qx t; then
        break
      fi
      sleep 2
    done
    # 等 agents 种子完成
    for i in $(seq 1 30); do
      n=$(psql -Atqc "SELECT count(*) FROM agents" 2>/dev/null | tr -d '[:space:]' || echo 0)
      [ "${n:-0}" -ge 8 ] && break
      sleep 2
    done

    applied=$(psql -Atqc "SELECT value FROM settings WHERE key='defaults.deployment_state'" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$applied" != "applied" ]; then
      if psql -v ON_ERROR_STOP=1 -q -f /app/defaults.sql >/tmp/defaults.log 2>&1; then
        armor=$(psql -Atqc "SELECT value FROM settings WHERE key='armor_enabled'" 2>/dev/null | tr -d '[:space:]' || true)
        if [ "$armor" = "true" ]; then
          psql -q -c "INSERT INTO settings(key,value) VALUES('defaults.deployment_state','applied') ON CONFLICT (key) DO UPDATE SET value='applied'" 2>/dev/null || true
          log "defaults.sql 已应用（破甲开关/预设/拦截规则）"
        else
          log "defaults.sql 执行了但 armor_enabled 未变为 true，见 /tmp/defaults.log"
        fi
      else
        log "defaults.sql 应用失败，见 /tmp/defaults.log"
      fi
    fi

    vapplied=$(psql -Atqc "SELECT value FROM settings WHERE key='redteam.visibility_state'" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$vapplied" != "applied" ] && [ -f /app/redteam/visibility.sql ]; then
      if psql -v ON_ERROR_STOP=1 -q -f /app/redteam/visibility.sql >/tmp/visibility.log 2>&1; then
        psql -q -c "INSERT INTO settings(key,value) VALUES('redteam.visibility_state','applied') ON CONFLICT (key) DO UPDATE SET value='applied'" 2>/dev/null || true
        log "visibility.sql 已应用（技能可见性）"
      else
        log "visibility.sql 应用失败，见 /tmp/visibility.log"
      fi
    fi
  ) &
fi

log "状态目录 $STATE（data / skills / redteam / jwt.key）"
exec /app/start.sh -data "$STATE/data" "$@"
