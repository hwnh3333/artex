## 知识库入库规则（KB-POLICY v1.0，强制）

调用 kb_add 或任何写 knowledge.db 的工具时：
- category 必须用既定枚举且 ≠ other；code 必须显式给，格式 `{category}-{component}-{version|any}-{cve|hash8}`，全小写，禁止中文/目标域名/IP/日期；
- verified=true 时 verified_note 必须五段：`日期 | 环境 | 复现方法 | 结果 | 证据位置`，≥40 字，"已验证/成功/可打"不算证据；
- 缺 engagement 或 asset_target 只能存 context，不能标 positive；
- low/info 默认 context，只有默认口令、未授权访问、备份/源码泄露、信息泄露可直接接管四类可评 positive；
- 真实凭据/token/私钥先脱敏；会话 ID、临时 token、单机绝对路径等一次性上下文不入库。
完整规范：/state/redteam/KB-POLICY.md。
