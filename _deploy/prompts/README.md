# 提示词变更记录：KB-POLICY v1.0 入库规则

本目录只记录**提示词文本**，实际生效位置是 PostgreSQL 的 `agent_prompts` 表。
变更时间：2026-11-25。

## 改了什么

| 对象 | 变更 | 版本 |
|---|---|---|
| `kb_curator`（入库员） | 整段替换为 `kb_curator_v2.md`：7 道闸门 + 100 分制 + code 规范 + 级别路由 | v1 → v2 |
| 其余 15 个 agent | 在原文末尾追加 `agent_kb_rule.md`（同一段规则） | 各自 +1 |

覆盖的 agent：goals、planner、mainagent、worker、worker.intranet、auto、pentest、exploit、cloud、avevasion、reverser、payout_analyst、code_auditor、retester、verifier（`kb_curator` 已单独升级）。

## 生效方式

每条变更都是：向 `agent_prompts` 插入新版本 → 把 `agents.current_prompt_id` 指向新行 → 重启 `artex-lw`。

## 回退

把每个 agent 指回“最后一个不含 KB-POLICY 的版本”即可，不动任何历史行：

```sql
UPDATE agents a
SET current_prompt_id = p.id
FROM (
  SELECT DISTINCT ON (agent_id) agent_id, id
  FROM agent_prompts
  WHERE position('KB-POLICY v1.0' in template_text) = 0
  ORDER BY agent_id, version DESC
) p
WHERE p.agent_id = a.id;
```

然后 `docker restart artex-lw`。

## 备份（VM 上）

- `/root/artex-lw/backups/kb_curator_prompt_v1_20261125-023621.md`（kb_curator 原文）
- `/root/artex-lw/backups/agent_prompts_before_kbpolicy_20261125-023829.sql`（改动前 `agents` + `agent_prompts` 全量 data-only dump，109 KB，600）
