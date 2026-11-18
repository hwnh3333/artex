#!/usr/bin/env bash
# 启动包装：导出 KB/工具路径并把 Python venv 加进 PATH，再交给守护脚本。
set -euo pipefail
cd "$(dirname "$0")"

export DSH_HOME="$(pwd)"
export ARTEX_HOME="$(pwd)"
export ARTEX_KB_DIR="$(pwd)/redteam"
if [ -d .venv/bin ]; then PATH="$(pwd)/.venv/bin:$PATH"; fi
export PATH

# 部署者默认配置：首次启动后应用一次（幂等，靠 defaults.deployment_state 标记）
(
  for i in $(seq 1 90); do
    curl -s -o /dev/null --max-time 2 http://127.0.0.1:8787/ && break
    sleep 2
  done
  CFGJSON="$(pwd)/config.json"
  [ -f "$CFGJSON" ] || exit 0
  PGPASS2="$(python3 -c "import json;print(json.load(open('$CFGJSON'))['database']['password'])" 2>/dev/null)"
  PGPORT2="$(python3 -c "import json;print(json.load(open('$CFGJSON'))['database']['port'])" 2>/dev/null)"
  [ -n "$PGPASS2" ] || exit 0
  PSQ="$(command -v psql || true)"
  if [ -z "$PSQ" ] && command -v brew >/dev/null 2>&1; then
    [ -x "$(brew --prefix postgresql@16 2>/dev/null)/bin/psql" ] && PSQ="$(brew --prefix postgresql@16)/bin/psql"
  fi
  [ -n "$PSQ" ] || exit 0
  APPLIED="$(PGPASSWORD="$PGPASS2" "$PSQ" -h 127.0.0.1 -p "$PGPORT2" -U postgres -d artex -tAc "SELECT value FROM settings WHERE key='defaults.deployment_state'" 2>/dev/null)"
  if [ "$APPLIED" != "applied" ]; then
    # 等 ARTEX 首次启动把表建好（最多 40 秒）
    for i in $(seq 1 20); do
      T="$(PGPASSWORD="$PGPASS2" "$PSQ" -h 127.0.0.1 -p "$PGPORT2" -U postgres -d artex -tAc "SELECT to_regclass('public.settings') IS NOT NULL" 2>/dev/null | tr -d '[:space:]')"
      [ "$T" = "t" ] && break
      sleep 2
    done
    ARMOR=""
    for try in 1 2 3; do
      PGPASSWORD="$PGPASS2" "$PSQ" -h 127.0.0.1 -p "$PGPORT2" -U postgres -d artex -q -v ON_ERROR_STOP=1 -f "$(pwd)/defaults.sql" 2>&1 | grep -i error || true
      ARMOR="$(PGPASSWORD="$PGPASS2" "$PSQ" -h 127.0.0.1 -p "$PGPORT2" -U postgres -d artex -tAc "SELECT value FROM settings WHERE key='armor_enabled'" 2>/dev/null | tr -d '[:space:]')"
      [ "$ARMOR" = "true" ] && break
      sleep 2
    done
    if [ "$ARMOR" = "true" ]; then
      PGPASSWORD="$PGPASS2" "$PSQ" -h 127.0.0.1 -p "$PGPORT2" -U postgres -d artex -q -c "INSERT INTO settings(key,value) VALUES('defaults.deployment_state','applied') ON CONFLICT (key) DO UPDATE SET value='applied'" 2>/dev/null
      printf "已应用部署者默认配置（破甲开关全开 / 预设 4 套 / 拦截规则 8 条）\n"
    else
      printf "部署者默认配置没能应用成功（armor_enabled 未变成 true）；面板可用，破甲可在 系统设置 里手动开启，下次启动会重试\n" >&2
    fi
  fi
) &
exec ./start.sh "$@"
