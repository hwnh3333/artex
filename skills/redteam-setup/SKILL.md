---
name: redteam-setup
description: ARTEX 红队环境检查与首次配置：确认 /state/redteam、工具链、API key、VPS 配置与知识库；dsh 的 setup.sh 已不适用
whenToUse: 用户第一次使用红队模式、说“环境没配好/工具装一下”，或需要确认 FOFA/Hunter/Quake/Shodan key、VPS 登录方式时
role: plan
enabled: true
---

# ARTEX 红队环境检查（适配版）

> 本技能原为 dsh-redteam-mode 的首次引导；ARTEX **没有** `redteam_preflight`、`setup.sh`、npm 安装器。下面按 ARTEX 的实际布局执行。

## 1. 先看已有什么（不要重复安装）

```bash
ls -la /state/redteam
ls -la /state/redteam/toolkit
cat /state/redteam/INSTALL-NOTES.md
```

ARTEX 已预装：
- 技能原文：`/state/redteam/skills/`（34 个 md）
- 知识库：`/state/redteam/knowledge.db`
- POC：`/state/redteam/pocs/`
- nuclei 模板：`/state/redteam/nuclei-templates/`
- 工具箱：`/state/redteam/toolkit/`

## 2. 工具自检

```bash
for t in nmap ffuf nuclei httpx subfinder dnsx naabu katana gospider \
         fscan gogo chisel frpc frps suo5 hydra proxychains4 sshpass \
         redis-cli mysql psql java tmux ncat socat sqlmap dirsearch jadx apktool; do
  command -v "$t" >/dev/null 2>&1 && echo "[y] $t" || echo "[-] $t"
done
command -v impacket-secretsdump >/dev/null 2>&1 && echo "[y] impacket" || echo "[-] impacket"
```

`[-]` 的处理顺序：先看技能里的降级步骤；确实需要系统包时，先向用户报告并获批，不要擅自 `apt install`。

## 3. 需要用户提供的外部配置

写入 `/state/redteam/.env`（已建，权限 600；不要提交真实密钥）后：

```bash
set -a; . /state/redteam/.env; set +a
```

- **FOFA**：`FOFA_KEY=`
- **Hunter**：`HUNTER_KEY=`
- **Quake**：`QUAKE_KEY=`
- **Shodan**：`SHODAN_KEY=`
- **VPS**：`REDTEAM_VPS_HOST=`、`REDTEAM_VPS_PORT=22`、`REDTEAM_VPS_USER=root`、`REDTEAM_VPS_PASS=` 或 `REDTEAM_VPS_KEY=`（私钥由用户自己上传，ARTEX 不复制原包 VPS 私钥）

说明：
- 只有 key、没有 VPS：侦察类技能可用，隧道/反弹 Shell 类技能不可用；如实说明，不要伪造通道。
- 只有 VPS、没有 key：被动侦察和手工命令可用，FOFA/Hunter/Quake/Shodan 自动化不可用。

## 4. 知识库

`/state/redteam/knowledge.db` 已存在，448 条（verified 378）。当前 ARTEX 二进制不含 `/api/kb/*`，所以：
- 先用 `sqlite3 /state/redteam/knowledge.db` 或技能里的本地文件方式查询；
- 不要把“知识库已落盘”说成“Web 知识库已启用”；
- 换老魏二进制并配置 `knowledge_dir`/`ARTEX_KB_DIR` 后才会在 Web 出现。

## 5. 常见缺失与替代

| 缺失 | 替代 |
|---|---|
| `msfconsole` | `nc`/`socat`/`python3` 监听（见 `shell-handler` 三级兜底） |
| MDUT / GSL5 / SuperShell MCP | 用手工 SQL/webshell 步骤；不要假装 MCP 调用成功 |
| `gospider` | 已补 `/state/redteam/toolkit/gospider/gospider` |
| `semgrep` | `code-audit` 的 grep 兜底 |
| 云厂商 CLI | `cloud-security` 的 curl/API 手工步骤 |

## 6. 不要做

- 不要运行原 `setup.sh` / `install-deps.sh`（会装 PostgreSQL、改系统配置，和 ARTEX 容器冲突）。
- 不要把 Windows 的 `jdk11/`、`pgsql/`、`*.exe` 搬进 Linux 容器。
- 不要为了“装齐”而离线爆破工具（`hashcat`/`john`）；与 `no-offline-bruteforce` 冲突。
