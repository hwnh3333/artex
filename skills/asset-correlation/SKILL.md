---
name: asset-correlation
description: 资产关联：域名↔IP↔C 段↔证书↔服务的图谱化
whenToUse: 同一目标已收集到多条域名/IP/C 段/证书/端口线索、要做信息收集阶段性收口、需要成图或发现同源关系（共享证书/同 C 段）时
role: recon
enabled: true
---
> **ARTEX 适配（安装时添加）**：本技能原为 dsh-redteam-mode 编写。ARTEX 没有 `redteam_*` 工具；遇到时按 `redteam-artex-compat` 的映射改用 `record_fact` / `report_finding` / `insert_assets`，或直接用 shell 完成。所有 `$DSH_HOME` 路径已适配为 `/state/redteam`。

## 关联规则
- 域名解析 → `resolves` 边（domain → asset）
- C 段归属 → `contains` 边（segment → asset）
- 端口开放 → `exposes` 边（asset → port）
- 证书 SAN 共享 → `shares_cert` 边

## 同 C 段特征比对（挖隐藏资产）
把已确认资产的 title / 页脚版权 / 备案号 / logo / favicon 哈希特征在同 C 段内逐个比对：命中特征但未被公开解析的 IP 就是隐藏资产，逐条 `redteam_asset_add` 落库（`provenance=passive`）。

## 落库要求
通过 redteam_asset_link 写入 edge 表；重复关系幂等。
