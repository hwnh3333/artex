---
name: redteam-artex-compat
description: ARTEX 红队技能兼容层：dsh `redteam_*` 工具到 ARTEX 工具的映射、/state/redteam 路径、已装/未装依赖与降级口径
whenToUse: 加载任何 redteam 技能前；技能正文出现 redteam_* 工具、$DSH_HOME、setup.sh 或 MCP 时
role: plan
enabled: true
---

# ARTEX 兼容层（dsh-redteam-mode → ARTEX）

## 一句话结论
这 34 个 redteam 技能原为 **dsh-redteam-mode** 编写，不是 ARTEX 原生技能。ARTEX **没有 `redteam_*` 系列工具**；不要按原名调用。能用 shell 的步骤直接执行；需要落库的按下表换成 ARTEX 工具；需要外部 key / VPS / MCP 的，先看本文「前置条件分类」。

## 工具映射（重要）

| 原 dsh 工具 | ARTEX 替代 | 用法要点 |
| --- | --- | --- |
| `redteam_asset_add` | `insert_assets` | 批量登记资产；root_domain/ip/subdomain/service/endpoint/app 等类型按 schema |
| `redteam_asset_link` | `insert_assets`（关系字段）或 `record_fact` | 资产关系写进事实 |
| `redteam_asset_query` / `redteam_asset_stats` / `redteam_credential_list` / `redteam_access_list` | `list_assets` / `list_facts` / `get_task_graph` | 查询，不要臆造结果 |
| `redteam_asset_test` | `record_fact` | 测试结论写事实，带 evidence/confidence |
| `redteam_chain_add` | `record_fact` | `summary`=一句话结论；`detail`=完整链路/命令/输出；`evidence`=关键一行；`confidence`=observed/inferred |
| `redteam_credential_add` | `record_fact` | 敏感值放 `detail`，不要放 `summary` |
| `redteam_access_add` | `record_fact` | 访问/权限结论 |
| `redteam_tunnel_add` / `redteam_tunnel_update` | `record_fact` | 隧道参数、状态、端点 |
| `redteam_session_check` | 手工 `ps`/`ss`/`tmux ls` + `record_fact` | ARTEX 无会话管理工具 |
| `redteam_vuln_add` | `report_finding` | 必须真实触发、有可复现证据；禁止版本匹配当漏洞 |
| `redteam_http_evidence_add` | `report_finding` 的 `evidence` / `record_fact` | 证据要可核对 |
| `redteam_attack_file_add` / `redteam_poc_add` / `redteam_poc_get` | 文件放 `/state/redteam/pocs/`，索引写 `record_fact` | 不要写 Windows 绝对路径 |
| `redteam_poc_search` | `grep -RIl` 本地 POC；知识库启用后用 `kb_search` | 当前 ARTEX 二进制未启用 kb API |
| `redteam_webshell_add` | `record_fact` | 记录 webshell 类型/路径/连接方式 |
| `redteam_preflight` | 本文「环境自检」 | dsh 专有，ARTEX 无 |

## 路径与变量
- 工具箱：`/state/redteam/toolkit/`
- POC：`/state/redteam/pocs/`
- 运行输出：`/state/redteam/runs/`（已创建）
- 知识库：`/state/redteam/knowledge.db`（当前 ARTEX 二进制没有 `/api/kb/*`，先按本地文件/`sqlite3` 用）
- VPS 配置：`/state/redteam/.env`（自己填；ARTEX 不复制 VPS 私钥）
- 原稿参考：`/state/redteam/skills/`（34 个 md）
- 技能目录：`/state/skills/<name>/SKILL.md`

VPS 相关变量（写入 `/state/redteam/.env` 后 `set -a; . /state/redteam/.env; set +a`）：
```bash
REDTEAM_VPS_HOST=
REDTEAM_VPS_PORT=22
REDTEAM_VPS_USER=root
REDTEAM_VPS_PASS=
# 或用私钥（自己上传，权限 600）：
# REDTEAM_VPS_KEY=/state/redteam/toolkit/vps/id_rsa
```
FOFA/HUNTER/QUAKE/SHODAN 同理：`FOFA_KEY=` / `HUNTER_KEY=` / `QUAKE_KEY=` / `SHODAN_KEY=`。

## 环境自检
```bash
for t in nmap ffuf nuclei httpx subfinder dnsx naabu katana gospider fscan gogo chisel frpc frps suo5 hydra proxychains4 sshpass redis-cli mysql psql java tmux ncat socat; do
  command -v "$t" >/dev/null 2>&1 && echo "[y] $t" || echo "[-] $t"
done
```
- `[-]` 不代表技能不能用：按技能里的降级/手工步骤走；不要为了一个步骤擅自 apt 安装。
- nuclei 模板：`/state/redteam/nuclei-templates`（`~/.config/nuclei/config.yaml` 已指向）。

## 前置条件分类（按当前 ARTEX 实测）
- **开箱即用（shell/方法论）**：`redteam-setup`、`active-scan`、`web-fingerprint`、`host-enum`、`asset-correlation`、`passive-recon`、`tunnel-selection`、`payout-flow-analysis`、`code-audit`（grep 兜底）、`cloud-security`（手工 API/curl）
- **需要本机二进制（已补）**：`recon-pipeline`、`dir-bruteforce`、`nuclei-scan`、`fscan-intranet`、`gogo-scan`、`credential-attack`、`lateral-movement`、`unauth-exploit`、`suo5-tunnel`、`chisel-tunnel`、`frp-tunnel`、`shell-handler`、`apk-recon`
- **需要用户提供配置**：`fofa-recon`、`hunter-recon`、`quake-recon`、`shodan-recon`（API key）；`vps-reverse-shell` / `*-tunnel`（VPS 配置）
- **需要 MCP/GUI（当前未配）**：`c2-supershell`（SuperShell MCP）、`db-utilization`（MDUT MCP）、`memshell-fallback`、`webshell-toolkit`（GSL5 MCP）

## 纪律
- 不要调用不存在的 `redteam_*`；不要假装调用成功。
- 不要 `unset` 代理、不要 `--noproxy`、不要原生 socket 直连；代理不通就停下报告（见 `proxy-only-egress`）。
- 不跑离线爆破（见 `no-offline-bruteforce`）；在线弱口令尝试/点名比对可以。
- 工具缺失时如实写阻塞，不要编造结果。
