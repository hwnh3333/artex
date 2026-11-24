# ARTEX 武器库（knowledge.db）质量准入规范 v1.0

> 适用范围：本规范只管**我们自己新增**的条目。老魏包自带的 537 条（`id <= 550`）保持只读，不评分、不改写、不追溯。
> 新条目判定线：`id >= 551` 或 `created_at >= 2026-11-25`，两者满足其一即适用本规范。
> 落地位置：`/root/artex-lw/KB-POLICY.md`、`/state/redteam/KB-POLICY.md`（容器内只读）。

---

## 1. 三层分类：先分清“武器 / 情报 / 负知识”

武器库不是“什么都收的备忘录”。每条新条目必须先归入以下三类之一，写入 `kb_entry_meta.polarity`：

| polarity | 含义 | 是否算“武器” | 典型内容 |
|---|---|---|---|
| `positive` | 可复用、已实测、有复现路径 | 是 | POC、利用链、默认口令、未授权接口 |
| `context` | 背景/情报，不能直接打 | 否 | 指纹、版本、拓扑、历史结论 |
| `negative` | 试过但失败/不可利用 | 否（负知识） | WAF 拦截、已修复、路径不存在、需要不存在的前提 |

硬规则：

- 新增条目**默认 `context`**，只有通过第 3 节评分且 ≥80 分才允许提升为 `positive`。
- `negative` 必须写清“为什么失败”，否则不入库。
- `positive` 不允许出现“疑似 / 可能 / 待验证”字样。

---

## 2. 硬性准入闸门（7 条，缺一即拒）

| # | 闸门 | 判定 |
|---|---|---|
| G1 | `category` 属于固定枚举且 ≠ `other` | 归不了类 → 拒 |
| G2 | `engagement_id`/`engagement_name` + `asset_target` 非空 | 无来源 → 拒 |
| G3 | `verified=1` 且 `verified_note` 满足“证据四要素” | 无证据 → 拒 |
| G4 | `code` 符合命名规范且语义去重通过 | 重复/命名脏 → 拒 |
| G5 | 至少有一种可复现载体：完整 HTTP 请求 / 命令 / 脚本 / 配置片段 | 只有结论 → 拒 |
| G6 | 无真实凭据、个人信息、私钥、token | 含敏感值 → 拒，脱敏后重提 |
| G7 | 不绑定一次性上下文（会话 ID、临时 token、时间戳路径、单台主机绝对路径） | 不可移植 → 拒 |

**直接拒绝清单**（不看分数）：

- 只有标题和“可利用”结论，没有请求/命令/步骤；
- 纯扫描器输出、banner、目录列表，没有验证动作；
- 同一 CVE / 同一组件同版本同类型的重复条目；
- 只能对单一目标生效、无法参数化的一次性 exploit（可降级为 `context` + `tags=one-off`）；
- 把账号密码、cookie、私钥写进 `code`/`title`/`engagement_name`；
- 标了 `verified=1` 但 `verified_note` 少于 40 字或没有日期。

---

## 3. 质量评分卡（100 分）

| 维度 | 分值 | 满分标准 |
|---|---|---|
| 可复现性 | 30 | `usage` 参数化完整，`content` 是最小可执行请求/脚本，依赖写清 |
| 证据强度 | 25 | 四要素齐全，证据可追溯（traffic id / 文件路径 / 截图） |
| 泛化程度 | 20 | 不绑定单一目标，版本范围明确，换目标只需改参数 |
| 唯一性 | 15 | 语义去重通过，`code` 规范，与现有条目无重叠 |
| 可维护性 | 10 | 来源可追溯，`tags` 完整，90 天内有复核 |

判定：

- **≥ 80** → `positive`，进武器库；
- **60–79** → `context`，留在候选池，补齐后可复评；
- **< 60** → 拒绝，或作为 `negative` 记录失败原因。

评分由 `kb_curator` 给出，人工抽检 10%。同一 `code` 复评时分数只升不降，降级必须写原因。

---

## 4. 字段填写规范

| 字段 | 必填 | 规则 |
|---|---|---|
| `code` | 是 | 见第 5 节，全局唯一，不含目标域名/中文/日期 |
| `title` | 是 | 一句话：`组件 + 版本 + 类型 + 效果`，≤ 80 字 |
| `kind` | 是 | 沿用老库：`poc` / `exp` / `script` / `template` / `payload` / `methodology`；只有 `poc`/`exp`/`script` 可评 `positive` |
| `category` | 是 | 固定枚举，见附录 A |
| `cve` | 否 | 有则填 `CVE-YYYY-NNNN`，没有留空，不编造 |
| `component` | 是 | 产品名小写：`thinkphp`、`shiro`、`fastjson` |
| `versions` | 是 | 受影响范围：`<= 5.0.23`、`2.0.0-2.0.5`；未知写 `unknown` |
| `severity` | 是 | `critical/high/medium/low/info`，按实际影响，不按标题党 |
| `source` | 是 | `self`（自己实测）/ `web` / `nuclei` / `manual` |
| `source_url` | 否 | 有出处就填，禁止死链 |
| `description` | 是 | 前置条件、影响、限制各一句 |
| `usage` | 是 | 参数化模板，用 `{target}`、`{user}`、`{pass}` 占位 |
| `content` | 是 | 最小可执行 payload/请求；大文件放 `path` |
| `verified` | 是 | 只有真跑通才为 1 |
| `verified_note` | 是 | 证据四要素，见下 |
| `engagement_id/name` | 是 | 来源任务，追溯用 |
| `asset_target` | 是 | 验证时的目标标识（域名/IP），不含账号密码 |
| `tags` | 是 | 至少 2 个：场景、前提、破坏性，见附录 B |
| `hit_count` / `used_on` | 否 | 由系统维护，不手填 |

**证据四要素**（`verified_note` 单行，竖线分隔）：

```
YYYY-MM-DD | 目标类型/环境 | 复现方法（请求或命令） | 结果（回显/权限/文件） | 证据位置（traffic id / 文件路径）
```

反例：`已验证`、`成功利用`、`可打`、`实测可用` —— 一律不认。

---

## 5. code 命名与去重

**格式**：

```
{category}-{component}-{version|any}-{cve|hash8}
```

- 全小写，只允许 `[a-z0-9._-]`，长度 8–80；
- `component` 用产品名，不用目标域名；
- 有 CVE 用 CVE 号，没有则用 `sha1(规范化 payload)` 前 8 位；
- 示例：`sqli-thinkphp-5.0.23-cve-2018-20062`、`auth-bypass-shiro-1.2.4-hash-a1b2c3d4`；
- 禁止：中文、IP、域名、日期、`测试`、`最终版`、随机串。

**语义去重键**：`category + component + versions + cve`（无 CVE 时用 `category + component + payload_hash`）。
入库前必须 `kb_search` 三次：按 `code`、按 `component`、按 `cve`；命中则合并，不新建。

合并规则：保留最早 `code`，更新 `verified_note` 与 `hit_count`，`tags` 取并集，不覆盖已有复用统计。

---

## 6. 严重级别的角色：只做路由，不做质量

级别不是准入条件，只决定进哪个池、走哪条复核路径：

| severity | 默认去向 | 复核 |
|---|---|---|
| critical / high | 候选池，可快速提升 | curator 复核即可 |
| medium | 候选池 | curator + 人工抽检 |
| low / info | 默认 `context` | 仅以下四类可提升为 `positive`：默认口令、未授权访问、备份/源码泄露、信息泄露可直接导致接管 |
| 空 | 强制 `context` | 先补级别 |

这样既不会把 info 一律挡在门外，也不会让“低危扫描结果”污染武器库。

---

## 7. 入库流程

```
自动回填 / agent kb_add
        │
        ▼
   candidate（polarity=context）
        │  kb_lint 通过？
        ▼
   kb_curator 打分（每周）
        │
   ┌────┴────┐
 ≥80        60–79 / <60
   │           │
positive    context / negative
   │
人工抽检 10% → 确认
```

- 自动回填的条目一律先落 `context`，不得直接视为武器；
- `kb_curator` 每周跑一次：规范化 `code`、语义去重、打分、升降级；
- 人工只审 `positive` 的新增与降级，不逐条审候选池；
- 删除任务前必须确认目标 finding 已入库（自动回填或 `kb_add`），否则先补录再删。

---

## 8. 生命周期

| 状态 | 触发 | 处理 |
|---|---|---|
| `active` | 评分 ≥80 且抽检通过 | 正常检索、推荐 |
| `deprecated` | 连续 3 次复用失败，或组件已淘汰 | 保留但不再推荐，`tags` 加 `deprecated` |
| `archived` | 12 个月 `hit_count=0` 且无人引用 | 移出检索默认集，不删除 |
| `negative` | 实测失败 | 记录失败原因，供后续排除 |

任何降级/归档都保留原条目，不物理删除。

---

## 9. 度量指标（每月看一次）

| 指标 | 目标 |
|---|---|
| 新增条目 `positive` 占比 | 20%–40%（太低说明门槛过严，太高说明放水） |
| 语义重复率 | < 5% |
| `positive` 条目证据四要素完整率 | 100% |
| `positive` 条目 30 天复用率 | > 20% |
| 复用成功率（`hit_count` 增长 / 被检索次数） | > 70% |
| `code` 规范符合率 | 100% |

---

## 10. 落地方式（不改二进制）

1. 本文件放 `/root/artex-lw/KB-POLICY.md`，并复制到 `state/redteam/KB-POLICY.md`，供 agent 读取。
2. `kb_lint.py` 只读扫描 `knowledge.db`，输出违规清单；**默认只报不改**。
3. `kb_curator` agent 的提示词追加本规范第 2–6 节，作为其打分依据。
4. 每周定时跑 `kb_lint.py --since-id 551`，报告落到 `/root/artex-lw/reports/`。
5. 批量修复只走 `kb_add`（同 `code` 覆盖）或人工确认后的 SQL，不直接改老数据。

---

## 附录 A：category 枚举

沿用老库既有分类，不另起一套：

`info-leak` `auth-bypass` `unauthorized` `rce` `recon` `methodology` `weak-password` `file-upload` `app-audit` `frontend-reverse` `env` `tunnel` `waf` `path-traversal` `ssrf` `sqli` `deserialization` `privesc` `protocol` `other`

- `other` 只允许出现在 `context`/`negative`，不得评 `positive`；
- 新增分类必须先改本文件并同步 `kb_lint.py`，不允许随手造词。

## 附录 B：kind 约定

`poc`（可复现验证）、`exp`（完整利用）、`script`（工具/脚本）、`template`（清单/速查）、`payload`（单点载荷）、`methodology`（方法论/判据）。

## 附录 C：tags 约定

- 场景：`web` `intranet` `cloud` `ad` `mobile` `api`
- 前提：`no-auth` `needs-auth` `needs-vpn` `needs-interaction`
- 影响：`rce` `takeover` `data-leak` `dos` `destructive`
- 质量：`deprecated` `one-off` `needs-review`
