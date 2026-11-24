#!/usr/bin/env bash
# ARTEX 老魏版一键部署/修复/重建脚本（同一套逻辑，自动检测）
#
# 用法：
#   ./redeploy.sh              # 自动检测：没部署就部署；已部署就补缺失/必要时重建
#   ./redeploy.sh --check      # 只检查，不改动
#   ./redeploy.sh --no-build   # 不构建镜像；镜像缺失则报错
#   ./redeploy.sh --force-build# 强制重新构建镜像
#   ./redeploy.sh --gate on    # 公网/VPS：开启 Gate 门控
#   ./redeploy.sh --gate off   # 内网：关闭 Gate 门控（新机器默认）
#
# 内存上限（写在 .env；已有值不覆盖）：
#   ARTEX_MEM_LIMIT=1920m  ARTEX_PG_MEM_LIMIT=384m
#
# 前置：
#   - 机器已安装 Docker + Docker Compose
#   - 当前目录是完整部署目录（Dockerfile、docker-compose.yml、fofa-recon/SKILL.md、本脚本）
#
# 数据：
#   - PostgreSQL 卷 artex-lw_pgdata：开始提示词、agent prompts、管理员密码哈希、会话、findings
#   - state/：knowledge.db、skills、FOFA .env
#   - 不要执行 docker compose down -v，不要删除 state/ 或 pgdata 卷。
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

COMPOSE=(docker compose)
APP="artex-lw"
PG="artex-lw-pg"
IMAGE="artex-lw:installed"
STATE="$ROOT/state"
ENV_FILE="$ROOT/.env"
FOFA_SRC="$ROOT/fofa-recon/SKILL.md"
FOFA_DST="$STATE/skills/fofa-recon/SKILL.md"
GATE_TOKEN_FILE="$ROOT/gate-token.txt"
STAMP="$ROOT/.image-built"
BACKUP_DIR="$ROOT/backups"
HOST_PORT="${HOST_PORT:-9787}"
URL="http://127.0.0.1:${HOST_PORT}"

# 镜像内必须可用的工具（缺一个就重建/报错，不静默跳过）
RUNTIME_TOOLS=(
  nxc nuclei sqlmap dirsearch impacket-psexec pypykatz jadx cfr apktool ffuf
  fscan gogo subfinder dnsx httpx katana naabu ksubdomain chisel frpc suo5
  gospider massdns nmap hydra sshpass proxychains4 tmux ncat socat psql sqlite3 java
)

CHECK_ONLY=0
NO_BUILD=0
FORCE_BUILD=0
GATE_MODE="${ARTEX_GATE:-}"
GATE_SET=0
[ -n "$GATE_MODE" ] && GATE_SET=1

while [ $# -gt 0 ]; do
  case "$1" in
    ""|redeploy) ;;
    --check|check) CHECK_ONLY=1; NO_BUILD=1 ;;
    --no-build) NO_BUILD=1 ;;
    --force-build) FORCE_BUILD=1 ;;
    --gate)
      [ $# -ge 2 ] || { echo "用法: $0 --gate on|off" >&2; exit 2; }
      GATE_MODE="$2"; GATE_SET=1; shift
      ;;
    --gate=*) GATE_MODE="${1#*=}"; GATE_SET=1 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "用法: $0 [--check|--no-build|--force-build|--gate on|off]" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; if [ "$rc" -ne 0 ]; then warn "执行失败（退出码 $rc）；备份目录：$BACKUP_DIR"; fi' EXIT

command -v docker >/dev/null 2>&1 || die "未找到 docker；请先安装 Docker"
docker compose version >/dev/null 2>&1 || die "未找到 docker compose"

env_get() {
  awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }' "$ENV_FILE" 2>/dev/null || true
}

ensure_key() {
  local key="$1" val="$2"
  if ! grep -q "^${key}=." "$ENV_FILE"; then
    if grep -q "^${key}=" "$ENV_FILE"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
      printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    fi
  fi
}

set_key() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

resolve_gate_mode() {
  local current answer
  current="$(env_get ARTEX_GATE | tr -d '\"')"
  if [ "$GATE_SET" = "1" ]; then
    case "$GATE_MODE" in
      on|off) ;;
      *) die "--gate 只能是 on 或 off" ;;
    esac
  elif [ -n "$current" ]; then
    GATE_MODE="$current"
  else
    GATE_MODE="off"
    if [ -t 0 ]; then
      printf 'Gate 门控 [on/off]（内网默认 off；公网/VPS 选 on）: ' >&2
      read -r answer
      case "$answer" in
        on|ON|On) GATE_MODE="on" ;;
      esac
    fi
  fi
  case "$GATE_MODE" in on|off) ;; *) die "ARTEX_GATE 只能是 on 或 off" ;; esac
}

ensure_gate_token() {
  [ "$GATE_MODE" = "on" ] || return 0
  local token
  token="${ARTEX_GATE_TOKEN:-$(env_get ARTEX_GATE_TOKEN | tr -d '\"')}"
  if [ -z "$token" ]; then
    token="$(openssl rand -hex 16)"
    set_key ARTEX_GATE_TOKEN "$token"
    log "已生成 Gate 口令（写入 .env；不打印）"
  fi
  printf '%s
' "$token" > "$GATE_TOKEN_FILE"
  chmod 600 "$GATE_TOKEN_FILE"
}

prepare_layout() {
  [ -f "$ROOT/Dockerfile" ] || die "缺少 $ROOT/Dockerfile；请把 _deploy 目录完整拷过来"
  [ -f "$ROOT/docker-compose.yml" ] || die "缺少 $ROOT/docker-compose.yml；请把 _deploy 目录完整拷过来"
  [ -f "$FOFA_SRC" ] || die "缺少 $FOFA_SRC；无法保证双模式 FOFA 技能"

  mkdir -p "$BACKUP_DIR" "$STATE"/{skills,redteam,data,home/.dsh}
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true

  resolve_gate_mode

  if [ ! -f "$ENV_FILE" ]; then
    local pw
    pw="$(openssl rand -hex 24)"
    cat > "$ENV_FILE" <<EOF
POSTGRES_PASSWORD=$pw
ARTEX_GATE=$GATE_MODE
APPLY_DEFAULTS=1
TZ=Asia/Shanghai
ARTEX_MEM_LIMIT=1920m
ARTEX_PG_MEM_LIMIT=384m
EOF
    chmod 600 "$ENV_FILE"
    log "新机器：已生成 .env（PostgreSQL 随机密码，不打印；Gate=$GATE_MODE）"
  fi

  if ! grep -q '^POSTGRES_PASSWORD=.' "$ENV_FILE"; then
    if docker volume inspect artex-lw_pgdata >/dev/null 2>&1; then
      die ".env 缺少 POSTGRES_PASSWORD，但 pgdata 卷已存在；拒绝自动改密码"
    fi
    local pw
    pw="$(openssl rand -hex 24)"
    if grep -q '^POSTGRES_PASSWORD=' "$ENV_FILE"; then
      sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$pw|" "$ENV_FILE"
    else
      printf 'POSTGRES_PASSWORD=%s\n' "$pw" >> "$ENV_FILE"
    fi
    chmod 600 "$ENV_FILE"
    warn "已补 POSTGRES_PASSWORD（仅新库）"
  fi

  set_key ARTEX_GATE "$GATE_MODE"
  ensure_gate_token
  ensure_key APPLY_DEFAULTS 1
  ensure_key TZ Asia/Shanghai
  # 只限制内存；已有 .env 里手工改过的值不会被覆盖。
  ensure_key ARTEX_MEM_LIMIT 1920m
  ensure_key ARTEX_PG_MEM_LIMIT 384m
  chmod 600 "$ENV_FILE"

  log "Gate 模式：$GATE_MODE（内网建议 off；公网/VPS 才用 on）"
  [ "$(env_get APPLY_DEFAULTS | tr -d '\"')" = "1" ] || warn "APPLY_DEFAULTS 当前不是 1；开始提示词/预设不会自动补"
}

wait_pg() {
  local i
  for i in $(seq 1 60); do
    docker exec "$PG" pg_isready -U artex -d artex >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

psql_scalar() {
  docker exec "$PG" psql -U artex -d artex -tAc "$1" 2>/dev/null \
    | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -n 1
}

start_pg() {
  "${COMPOSE[@]}" up -d postgres >/dev/null
  wait_pg || die "PostgreSQL 未就绪"
}

db_has_schema() {
  [ -n "$(psql_scalar "select to_regclass('public.settings')")" ]
}

backup_if_needed() {
  start_pg
  if ! db_has_schema; then
    log "数据库还是空的（新机器/新卷），跳过备份"
    return 0
  fi

  local ts="$1"
  log "备份数据库与配置"
  if docker exec "$PG" pg_dump -U artex -d artex -Fc \
      > "$BACKUP_DIR/artex-db-$ts.dump" 2>"$BACKUP_DIR/pg_dump-$ts.err"; then
    chmod 600 "$BACKUP_DIR/artex-db-$ts.dump"
    log "数据库备份：$BACKUP_DIR/artex-db-$ts.dump"
  else
    warn "pg_dump 失败，详见 $BACKUP_DIR/pg_dump-$ts.err"
    rm -f "$BACKUP_DIR/artex-db-$ts.dump"
  fi

  cp "$ENV_FILE" "$BACKUP_DIR/env-$ts" 2>/dev/null || true
  cp "$STATE/redteam/.env" "$BACKUP_DIR/fofa-env-$ts" 2>/dev/null || true
  [ -f "$STATE/config.json" ] && cp "$STATE/config.json" "$BACKUP_DIR/config-$ts.json" || true
  [ -f "$FOFA_DST" ] && cp "$FOFA_DST" "$BACKUP_DIR/fofa-skill-$ts.md" || true
  [ -f "$STATE/redteam/knowledge.db" ] && cp "$STATE/redteam/knowledge.db" "$BACKUP_DIR/knowledge-$ts.db" || true
  chmod 600 "$BACKUP_DIR"/*-"$ts"* 2>/dev/null || true

  find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name 'artex-db-*.dump' -o -name 'knowledge-*.db' \) \
    -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | tail -n +6 | cut -d' ' -f2- | xargs -r rm -f
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' \
    -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | tail -n +6 | cut -d' ' -f2- | xargs -r rm -f
}

ensure_fofa_env() {
  local fenv="$STATE/redteam/.env"
  touch "$fenv"
  chmod 600 "$fenv"

  if grep -q '^FOFA_KEY=.' "$fenv" || grep -q '^FOFA_KEYS=.' "$fenv"; then
    return 0
  fi

  if [ -n "${FOFA_KEY:-}" ]; then
    printf 'FOFA_KEY=%s\n' "$FOFA_KEY" >> "$fenv"
    [ -n "${FOFA_POOL_BASE:-}" ] && printf 'FOFA_POOL_BASE=%s\n' "$FOFA_POOL_BASE" >> "$fenv"
    chmod 600 "$fenv"
    log "已从环境变量写入 FOFA 配置"
    return 0
  fi

  if [ -t 0 ]; then
    local key base
    printf 'FOFA 令牌（直接回车跳过，稍后可在 /state/redteam/.env 补）: ' >&2
    read -r -s key
    printf '\n' >&2
    if [ -n "$key" ]; then
      printf 'FOFA_KEY=%s\n' "$key" >> "$fenv"
      printf 'FOFA_POOL_BASE（回车=官方；号池填 https://fofa.ssgonet.com）: ' >&2
      read -r base
      [ -n "$base" ] && printf 'FOFA_POOL_BASE=%s\n' "$base" >> "$fenv"
      chmod 600 "$fenv"
      log "FOFA 配置已写入 state/redteam/.env"
      return 0
    fi
  fi

  warn "FOFA_KEY 未设置；fofa-recon 暂时不可用（不影响 ARTEX 启动）"
}

install_fofa_skill() {
  [ -f "$FOFA_SRC" ] || { warn "缺少 FOFA 技能源文件，跳过"; return 0; }
  mkdir -p "$(dirname "$FOFA_DST")" "$STATE/skills"
  cp "$FOFA_SRC" "$FOFA_DST"
  # 不再写 /state/skills/fofa-recon.md：技能列表会把目录格式和扁平格式当成两个同名技能。
  # 新机器时 /state/redteam 由 entrypoint 整体播种；这里只补已存在的旧技能树。
  if [ -d "$STATE/redteam/skills" ]; then
    cp "$FOFA_SRC" "$STATE/redteam/skills/fofa-recon.md"
  fi
  chmod 644 "$FOFA_DST"
  log "FOFA 双模式技能已写入 state（目录格式 + redteam 兼容副本）"
}

cleanup_vps_state() {
  local p removed=0
  for p in \
    "$STATE/redteam/toolkit/vps" \
    "$STATE/redteam/skills/vps-reverse-shell.md" \
    "$STATE/skills/vps-reverse-shell" \
    "$STATE/skills/vps-reverse-shell.md"; do
    if [ -e "$p" ]; then
      rm -rf -- "$p"
      removed=1
    fi
  done
  if [ "$removed" = "1" ]; then
    log "已清理 state 中残留的 VPS 工具/技能"
  fi
  return 0
}

image_exists() { docker image inspect "$IMAGE" >/dev/null 2>&1; }

image_skill_hash() {
  docker run --rm --entrypoint sha256sum "$IMAGE" /app/skills/fofa-recon/SKILL.md 2>/dev/null \
    | awk '{print $1}' || true
}

image_has_nxc() {
  docker run --rm --entrypoint sh "$IMAGE" -c 'command -v nxc >/dev/null 2>&1'
}

image_has_vps() {
  docker run --rm --entrypoint test "$IMAGE" -d /app/redteam/toolkit/vps >/dev/null 2>&1
}

image_has_tools() {
  # 入口脚本启动后才会补 /usr/local/bin 软链，所以这里检查镜像内的原始路径。
  docker run --rm --entrypoint sh "$IMAGE" -c '
    set -e
    test -x /usr/local/bin/nxc
    test -x /app/redteam/toolkit/nuclei/nuclei
    test -x /app/.venv/bin/sqlmap
    test -x /app/.venv/bin/dirsearch
    test -e /app/.venv/bin/psexec.py
    test -x /app/.venv/bin/pypykatz
    test -x /app/redteam/toolkit/jadx/bin/jadx
    test -f /app/redteam/toolkit/decompilers/cfr.jar
    test -x /usr/bin/apktool
    test -x /app/redteam/toolkit/ffuf/ffuf
    test -x /app/redteam/toolkit/fscan/fscan
    test -x /app/redteam/toolkit/gogo/gogo
    test -x /app/redteam/toolkit/subfinder/subfinder
    test -x /app/redteam/toolkit/dnsx/dnsx
    test -x /app/redteam/toolkit/httpx/httpx
    test -x /app/redteam/toolkit/katana/katana
    test -x /app/redteam/toolkit/naabu/naabu
    test -x /app/redteam/toolkit/ksubdomain/ksubdomain
    test -x /app/redteam/toolkit/chisel/chisel
    test -x /app/redteam/toolkit/frp/frpc
    test -x /app/redteam/toolkit/suo5/suo5-linux-amd64
    test -x /app/redteam/toolkit/gospider/gospider
    test -x /app/redteam/toolkit/massdns/massdns
    test -x /usr/bin/nmap
    test -x /usr/bin/hydra
    test -x /usr/bin/sshpass
    test -x /usr/bin/proxychains4
    test -x /usr/bin/tmux
    test -x /usr/bin/ncat
    test -x /usr/bin/socat
    test -x /usr/bin/psql
    test -x /usr/bin/sqlite3
    test -x /usr/bin/java
    test -d /app/redteam/nuclei-templates
  ' >/dev/null 2>&1
}

need_build() {
  [ "$FORCE_BUILD" = "1" ] && return 0
  image_exists || return 0

  local src_hash
  src_hash="$(sha256sum "$FOFA_SRC" | awk '{print $1}')"
  [ "$src_hash" != "$(image_skill_hash)" ] && return 0
  image_has_nxc || return 0
  image_has_tools || return 0
  if image_has_vps; then return 0; fi

  if [ -f "$STAMP" ]; then
    [ "$ROOT/Dockerfile" -nt "$STAMP" ] && return 0
    [ "$FOFA_SRC" -nt "$STAMP" ] && return 0
  fi
  return 1
}

build_image() {
  [ "$NO_BUILD" = "1" ] && die "需要构建镜像，但指定了 --no-build"
  log "构建镜像 $IMAGE"
  "${COMPOSE[@]}" build artex
  touch "$STAMP"
}

ensure_app() {
  start_pg
  log "启动/更新 app 容器（保留 PostgreSQL 与 state）"
  "${COMPOSE[@]}" up -d artex
}

wait_health() {
  local mode="${1:-$(env_get ARTEX_GATE | tr -d '\"')}" i code
  if [ "$mode" = "on" ]; then
    # Gate on 时所有路径都被伪装页接住；用 200 判断进程已起来，
    # 真正的数据库/业务健康在临时 off 和 defaults 检查里验证。
    for i in $(seq 1 120); do
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$URL/" 2>/dev/null || true)"
      [ "$code" = "200" ] && return 0
      sleep 2
    done
    return 1
  fi
  for i in $(seq 1 120); do
    curl -fsS --max-time 3 "$URL/api/health" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

post_start() {
  docker exec "$APP" ln -sfn /state/redteam/.env /state/home/.dsh/.env 2>/dev/null || true
  install_fofa_skill

  if [ ! -s "$STATE/redteam/knowledge.db" ]; then
    if docker cp "$APP:/app/redteam/knowledge.db" "$STATE/redteam/knowledge.db" 2>/dev/null; then
      log "已从镜像恢复 knowledge.db"
    else
      warn "knowledge.db 缺失，且无法从镜像恢复"
    fi
  fi

  if [ ! -d "$STATE/redteam/nuclei-templates" ]; then
    if docker cp "$APP:/app/redteam/nuclei-templates" "$STATE/redteam/" 2>/dev/null; then
      log "已从镜像恢复 nuclei-templates"
    else
      warn "nuclei-templates 缺失，且无法从镜像恢复"
    fi
  fi
}

ensure_admin() {
  local status pass payload restarted=0 gate_mode
  gate_mode="$(env_get ARTEX_GATE | tr -d '\"')"
  status="$(curl -fsS --max-time 5 "$URL/api/auth/status" 2>/dev/null || true)"

  # Gate 开启后 /api/auth/status 会返回 200 的假 nginx 页，不是 JSON；
  # 所以 Gate on 时一律临时 off，完成管理员校验/初始化后再切回 on。
  if [ "$gate_mode" = "on" ]; then
    log "Gate on：临时以 Gate off 启动，完成管理员校验/初始化后再切回 on"
    ARTEX_GATE=off "${COMPOSE[@]}" up -d artex >/dev/null || die "临时关闭 Gate 启动失败"
    wait_health off || die "临时关闭 Gate 后健康检查失败"
    restarted=1
    status="$(curl -fsS --max-time 5 "$URL/api/auth/status" 2>/dev/null || true)"
  fi

  if printf '%s' "$status" | grep -q '"initialized":true'; then
    log "管理员已初始化，保留现有密码"
    if [ "$restarted" = "1" ]; then
      log "恢复 Gate on"
      ensure_app
      wait_health on || die "恢复 Gate 后健康检查失败"
    fi
    return 0
  fi

  if [ -s "$ROOT/admin-password.txt" ]; then
    pass="$(tr -d '\r\n' < "$ROOT/admin-password.txt")"
  else
    pass="$(openssl rand -hex 16)"
    printf '%s\n' "$pass" > "$ROOT/admin-password.txt"
    chmod 600 "$ROOT/admin-password.txt"
  fi

  if command -v python3 >/dev/null 2>&1; then
    payload="$(python3 -c 'import json,sys; print(json.dumps({"password":sys.argv[1]}))' "$pass")"
  else
    payload="{\"password\":\"$pass\"}"
  fi

  if curl -fsS --max-time 10 -X POST "$URL/api/auth/init" \
      -H 'Content-Type: application/json' --data "$payload" >/dev/null 2>&1; then
    log "首次管理员已初始化，密码写入 $ROOT/admin-password.txt"
  else
    warn "管理员初始化失败；请打开 $URL 手动设置密码"
  fi

  if [ "$restarted" = "1" ]; then
    log "恢复 Gate on"
    ensure_app
    wait_health on || die "恢复 Gate 后健康检查失败"
  fi
}

gate_info() {
  local mode path
  mode="$(env_get ARTEX_GATE | tr -d '\"')"
  if [ "$mode" != "on" ]; then
    printf 'gate: off\n'
    printf 'access: http://192.168.3.166:%s/  (user: ARTEX)\n' "$HOST_PORT"
    return 0
  fi

  path="$(docker exec "$APP" sh -c 'cat /state/data/gate.path 2>/dev/null' 2>/dev/null | tr -d '\r\n' || true)"
  if [ -n "$path" ]; then
    printf 'gate: on entry=http://192.168.3.166:%s%s\n' "$HOST_PORT" "$path"
  else
    warn "Gate on，但 /state/data/gate.path 还没生成"
  fi

  if [ -s "$GATE_TOKEN_FILE" ]; then
    printf '%s\n' "gate_password_file: $GATE_TOKEN_FILE (600)"
  else
    warn "Gate 口令文件缺失：$GATE_TOKEN_FILE"
  fi
}

wait_defaults() {
  local apply i st
  apply="$(env_get APPLY_DEFAULTS | tr -d '\"')"
  if [ "$apply" != "1" ]; then
    log "APPLY_DEFAULTS=$apply，跳过 defaults.sql 等待"
    return 0
  fi

  log "等待 defaults.sql / 开始提示词就绪"
  for i in $(seq 1 60); do
    st="$(psql_scalar "select value from settings where key='defaults.deployment_state'")"
    [ "$st" = "applied" ] && return 0
    sleep 2
  done
  warn "defaults.deployment_state 不是 applied；请查看 docker compose logs artex"
  return 1
}

verify_all() {
  log "校验当前实例"

  local health auth defaults armor presets intercepts prompts prompt_len gate_mode
  gate_mode="$(env_get ARTEX_GATE | tr -d '\"')"
  if [ "$gate_mode" = "on" ]; then
    printf '%s\n' 'health: gate-on (nginx cover; real health checked during admin step)'
    printf '%s\n' 'auth: gate-on (management UI behind gate)'
  else
    health="$(curl -fsS --max-time 5 "$URL/api/health" 2>/dev/null || true)"
    [ -n "$health" ] || die "健康检查失败：$URL/api/health"
    printf '%s\n' "health: $health"

    auth="$(curl -fsS --max-time 5 "$URL/api/auth/status" 2>/dev/null || true)"
    printf '%s\n' "auth: ${auth:-未读取到}"
  fi


  if docker ps --format '{{.Names}}' | grep -qx "$APP"; then
    printf 'container: %s\n' "$(docker inspect -f '{{.Config.Image}}' "$APP")"
  else
    warn "$APP 容器未运行"
  fi

  defaults="$(psql_scalar "select value from settings where key='defaults.deployment_state'")"
  armor="$(psql_scalar "select value from settings where key='armor_enabled'")"
  presets="$(psql_scalar "select count(*) from armor_presets")"
  intercepts="$(psql_scalar "select count(*) from intercept_rules")"
  prompts="$(psql_scalar "select count(*) from agent_prompts")"
  prompt_len="$(psql_scalar "select coalesce(length(value),0) from settings where key='armor_prompt'")"
  printf 'db: defaults=%s armor_enabled=%s armor_presets=%s intercept_rules=%s agent_prompts=%s armor_prompt_len=%s\n' \
    "${defaults:-?}" "${armor:-?}" "${presets:-?}" "${intercepts:-?}" "${prompts:-?}" "${prompt_len:-0}"
  [ "${prompt_len:-0}" -gt 0 ] || warn "armor_prompt 为空；开始提示词可能未应用"

  if [ -f "$FOFA_SRC" ] && [ -f "$FOFA_DST" ]; then
    local src_hash state_hash img_hash
    src_hash="$(sha256sum "$FOFA_SRC" | awk '{print $1}')"
    state_hash="$(sha256sum "$FOFA_DST" | awk '{print $1}')"
    img_hash="$(image_skill_hash)"
    printf 'fofa_skill: src=%s state=%s image=%s\n' "${src_hash:0:12}" "${state_hash:0:12}" "${img_hash:0:12}"
    [ "$src_hash" = "$state_hash" ] || warn "state 里的 FOFA 技能与源文件不一致"
    [ "$src_hash" = "$img_hash" ] || warn "镜像里的 FOFA 技能与源文件不一致"
  fi

  printf 'fofa_env: %s\n' "$(docker exec "$APP" sh -c 'set -a; . /state/home/.dsh/.env 2>/dev/null; set +a; n=0; [ -n "${FOFA_KEYS:-}" ] && n=$(printf "%s" "$FOFA_KEYS" | tr "," " " | wc -w); [ "$n" -eq 0 ] && [ -n "${FOFA_KEY:-}" ] && n=1; printf "keys=%s pool_base=%s" "$n" "${FOFA_POOL_BASE:-}"' 2>/dev/null || true)"

  printf 'knowledge: %s\n' "$(docker exec "$APP" sh -c 'sqlite3 /state/redteam/knowledge.db "pragma integrity_check; select count(*) from poc;"' 2>/dev/null | tr '\n' ' ' || true)"

  local vps_bad=0 p
  for p in \
    /app/redteam/toolkit/vps \
    /state/redteam/toolkit/vps \
    /app/skills/vps-reverse-shell \
    /state/skills/vps-reverse-shell \
    /app/skills/vps-reverse-shell.md \
    /state/skills/vps-reverse-shell.md; do
    if docker exec "$APP" test -e "$p" 2>/dev/null; then
      warn "VPS 残留：$p"
      vps_bad=1
    fi
  done
  if [ "$vps_bad" = "0" ]; then
    printf 'vps_toolkit: removed\n'
  fi

  local missing="" c
  for c in "${RUNTIME_TOOLS[@]}"; do
    docker exec "$APP" sh -c "command -v $c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    warn "容器内缺少工具:$missing"
  else
    printf 'tools: ok (%s)\n' "${#RUNTIME_TOOLS[@]}"
  fi

  local nxc
  nxc="$(docker exec "$APP" nxc --version 2>/dev/null | tail -n 1 || true)"
  printf 'nxc: %s\n' "${nxc:-未安装}"

  local app_mem pg_mem mem_avail disk_avail
  app_mem="$(docker inspect -f '{{.HostConfig.Memory}}' "$APP" 2>/dev/null || echo 0)"
  pg_mem="$(docker inspect -f '{{.HostConfig.Memory}}' "$PG" 2>/dev/null || echo 0)"
  printf 'limits: app_mem=%sMiB pg_mem=%sMiB\n' \
    "$((app_mem / 1024 / 1024))" "$((pg_mem / 1024 / 1024))"
  [ "${app_mem:-0}" -gt 0 ] || die "app 未设置内存上限（mem_limit）"
  [ "${pg_mem:-0}" -gt 0 ] || die "PostgreSQL 未设置内存上限（mem_limit）"

  mem_avail="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  disk_avail="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
  printf 'host: mem_available=%sMiB disk_available=%sMiB\n' "${mem_avail:-0}" "${disk_avail:-0}"
  [ "${mem_avail:-0}" -ge 300 ] || warn "宿主机可用内存低于 300MiB"
  [ "${disk_avail:-0}" -ge 1024 ] || warn "根分区可用磁盘低于 1GiB"

  [ "$vps_bad" = "0" ] || die "存在 VPS 残留，部署未完成"
  [ -z "$missing" ] || die "容器内缺少工具，部署未完成"
  docker exec "$APP" test -d /state/redteam/nuclei-templates \
    || die "nuclei-templates 缺失"

  if [ -f "$ROOT/admin-password.txt" ]; then
    printf 'admin_password_file: %s (600)\n' "$ROOT/admin-password.txt"
  else
    warn "未找到 admin-password.txt；如未初始化请打开页面设置"
  fi

  gate_info
}

main() {
  if [ "$CHECK_ONLY" = "1" ]; then
    verify_all
    return 0
  fi

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  prepare_layout
  start_pg
  backup_if_needed "$ts"
  cleanup_vps_state
  ensure_fofa_env
  install_fofa_skill

  if need_build; then
    build_image
  else
    log "镜像已存在且技能/工具/NetExec/VPS 清理均满足，跳过构建"
    touch "$STAMP"
  fi

  ensure_app
  if ! wait_health; then
    warn "健康检查超时，尝试重启 app 一次"
    docker restart "$APP" >/dev/null 2>&1 || true
    if ! wait_health; then
      warn "仍在失败，最近日志："
      "${COMPOSE[@]}" logs --tail=80 artex >&2 || true
      die "app 未就绪"
    fi
  fi

  post_start
  ensure_admin
  wait_defaults || true
  verify_all
  log "完成"
}

main
