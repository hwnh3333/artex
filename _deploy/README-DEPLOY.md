# ARTEX 老魏版 Docker 部署（独立实例）

## 访问

- 地址：`http://192.168.3.166:9787/`
- 用户名：`ARTEX`
- 密码：`/root/artex-lw/admin-password.txt`（权限 600，仅 root 可读）

未使用宿主机的 8787/5432；原有 `artex` / `artex-pg` 生产容器未动。

## 一键部署 / 修复 / 重建（自动检测）

前置：机器已装 Docker + Docker Compose，当前目录是完整的 `_deploy` 部署目录。

```bash
cd /root/artex-lw
./redeploy.sh
```

同一个脚本自动判断：

- **没有部署**：生成 `.env`、启动 PostgreSQL、构建 `artex-lw:installed`、启动 app；
  如果数据库是空的，entrypoint 应用 `defaults.sql`，脚本再初始化管理员密码并写入
  `admin-password.txt`。
- **已有容器**：先备份数据库/配置，检查技能、NetExec、VPS 清理是否满足；
  缺什么补什么，镜像内容不匹配才重建。
- **已有数据库**：不会重新执行 `defaults.sql`，不会覆盖开始提示词、agent prompts、
  知识库、密码和会话。

常用参数：

```bash
./redeploy.sh --check       # 只检查，不改动
./redeploy.sh --no-build    # 不构建镜像；镜像缺失则报错
./redeploy.sh --force-build # 强制重新构建镜像
./redeploy.sh --gate on     # 公网/VPS：开启 Gate 门控
./redeploy.sh --gate off    # 内网：关闭 Gate 门控（默认）
```

新机器首次运行如果终端可交互，会询问 Gate 模式；直接回车按 `off`。
非交互环境默认 `off`。已有实例不传 `--gate` 时保持 `.env` 里现有值。

**不要执行 `docker compose down -v`，不要删除 `state/` 或 `artex-lw_pgdata`**。
开始提示词、agent prompts、登录密码哈希、会话和 findings 在 PostgreSQL 卷里；
`knowledge.db`、skills、FOFA `.env` 在 `state/` 里。

## 目录

- 部署目录：`/root/artex-lw`
- 数据卷：`/root/artex-lw/state`（skills / redteam / data / jwt.key）
- PostgreSQL 卷：`artex-lw_pgdata`
- 镜像：`artex-lw:installed`
- 容器：`artex-lw`、`artex-lw-pg`

## 本次在容器内补装的内容

基础镜像 `ghcr.io/hwnh3333/artex:latest` 已带：
nmap / hydra / sshpass / proxychains4 / tmux / ncat / socat / psql / sqlite3 /
openjdk-17 / apktool / impacket / sqlmap / dirsearch / pypykatz /
fscan / gogo / subfinder / dnsx / httpx / katana / naabu / ksubdomain /
chisel / frp / suo5 / nuclei 3.11.1 / ffuf / gospider / massdns / jadx / cfr。

脚本启动后会校验这 33 个工具和 `/app/redteam/nuclei-templates`；
缺任何一个会直接报错，不会静默跳过。

派生镜像额外安装：
- NetExec 1.5.1（`nxc` / `netexec` / `nxcdb`），装在独立 venv `/opt/netexec`，
  不污染 `/app/.venv`。v1.5.1 直接 pip 安装会因 certipy 包名冲突失败，
  已用 `--no-deps` + 手工依赖 + `certipy-ad==5.0.4` 绕过。
- 补执行位：nuclei/fscan/gogo/.../jadx。
- 删除 VPS 中转工具与专用技能：
  `/app/redteam/toolkit/vps`、`/state/redteam/toolkit/vps`、
  `skills/vps-reverse-shell`。脚本还会清理 `state` 里从旧实例带过来的
  `state/redteam/toolkit/vps` 和 `state/skills/vps-reverse-shell*`。
  未配置任何 VPS 地址、私钥或代理。

未安装到宿主机：PostgreSQL、JDK、nmap、Python 工具等全部在容器/镜像内。
PostgreSQL 用独立 `postgres:16-alpine` 容器。

## 内存上限（防止 VM 被任务撑爆）

这台 VM 只有约 3.8G 内存。`artex-lw` 里的 Playwright、jadx/cfr/apktool、扫描工具会临时吃内存；
之前容器没有内存上限，任务并发时会把宿主机拖进 OOM/重启。

现在只在容器层限制内存，不限制 worker 数、任务并发、CPU 或 PID：

| 变量 | 默认值 | 作用 |
|---|---|---|
| `ARTEX_MEM_LIMIT` | `1920m` | app 容器内存上限；同时作为 swap 上限，禁止额外吃宿主 swap |
| `ARTEX_PG_MEM_LIMIT` | `384m` | PostgreSQL 内存上限 |

容器日志限制为单文件 20MB、保留 3 份，避免日志撑满磁盘。

调整示例：

```bash
cd /root/artex-lw
# 更保守：app 1.875G、PostgreSQL 384M
sed -i 's/^ARTEX_MEM_LIMIT=.*/ARTEX_MEM_LIMIT=1920m/' .env
sed -i 's/^ARTEX_PG_MEM_LIMIT=.*/ARTEX_PG_MEM_LIMIT=384m/' .env
./redeploy.sh --no-build
```

`--check` 会输出 `limits: app_mem=... pg_mem=...`；缺少内存上限会直接报错。

## 环境变量要点

- `APPLY_DEFAULTS=1`：已执行 `defaults.sql`，破甲开关/4 套预设/8 条拦截规则已生效。
  执行前已备份数据库：`/root/artex-lw/backup-before-defaults-20261119-062910.dump`。
- `ARTEX_GATE`：内网默认 `off`，直接走应用登录页；公网/VPS 才建议 `on`。
  切换用 `./redeploy.sh --gate on|off`，不要只改 `.env` 后不重建容器。
  Gate on 后入口路径写在容器 `/state/data/gate.path`，脚本会输出完整入口；
  登录口令由脚本生成在 `.env` 的 `ARTEX_GATE_TOKEN`，并复制到宿主机
  `gate-token.txt`（600）。在入口页输入这个口令即可，不是 `/app/gate.key`
  （那是 cookie 签名 key，不是登录密码）。
  首次部署选择 `on` 时，脚本会先用 `off` 完成管理员初始化，再切回 `on`。
- `DSH_HOME=/state/home/.dsh`、`ARTEX_HOME=/app`、`ARTEX_KB_DIR=/state/redteam`，
  等价于裸机 `start-artex.sh` 的路径导出。

## FOFA 双模式

首次运行如果终端可交互，脚本会询问 FOFA 令牌和号池 base；直接回车则跳过，
之后在 `state/redteam/.env` 手动补。非交互运行只提示、不阻塞。

- 默认官方：不写 `FOFA_POOL_BASE`，`FOFA_KEY` 填官方 key。
- 号池：`state/redteam/.env` 里写 `FOFA_POOL_BASE=https://fofa.ssgonet.com`，
  `FOFA_KEY` 或 `FOFA_KEYS` 填号池令牌。
- 多 key：`FOFA_KEYS=key1,key2,key3`，或分行写 `FOFA_KEY_1=...`、`FOFA_KEY_2=...`；
  客户端遇到 401/403/402/429 或额度不足会自动切下一个 key，不需要手动换。
- 官方兼容镜像：写 `FOFA_API_BASE=https://镜像域名`，不写 `FOFA_POOL_BASE`。

修改后不需要重启，下一次技能运行会重新读取 `/state/redteam/.env`。

## 常用命令

```bash
cd /root/artex-lw
docker compose ps
docker compose logs -f artex
docker compose restart artex
docker compose down          # 保留 state 和 pgdata
docker compose up -d
```

查看密码：

```bash
cat /root/artex-lw/admin-password.txt
```

修改密码：登录后页面修改，或调 `/api/auth/change-password`。

## 注意

- 备份目录：`/root/artex-lw/backups`，权限 600；脚本默认保留最近 5 份数据库/知识库备份。
- 当前镜像/知识库仍来自公开 GHCR 包，`knowledge.db` 与 `pocs` 内含真实第三方
  目标数据；本实例只在本机 LAN 使用，不要再次公开镜像或转发 `state/`。
- `redteam/toolkit/vps` 已删除；`fscan-intranet`、`gogo-scan`、`shell-handler`
  等技能里仍有“用 vps.sh 分发载荷”的备选描述，按需忽略或自行改写。
- 应用内 `/api/vps` 页面仍存在（空配置），不影响使用；未接任何 VPS。

## 知识库质量规范（KB-POLICY v1.0）

- 规范文件：`/root/artex-lw/KB-POLICY.md`，容器内副本 `/state/redteam/KB-POLICY.md`。
- 只读体检：`python3 /root/artex-lw/kb_lint.py --db <knowledge.db 副本>`；
  默认只扫 `id >= 551` 的新数据，老魏自带 537 条（max id=550）不评分、不改写。
- 新数据判定：统一用 `id >= 551`，不用日期。id 单调递增且不可回填，日期可能被导入数据带旧值。
- `kb_curator` 的提示词已升级到 v2（`agent_prompts.version=2`），按 7 道闸门 + 100 分制打分；
  旧版备份在 `/root/artex-lw/backups/kb_curator_prompt_v1_*.md`。
- 不做定时报告；需要时让平台内 LLM 跑 `kb_lint.py --json` 再总结。
