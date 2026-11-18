---
name: version-pinning
description: 把静态资产指纹（SRI / sha256 / sha1）反查为上游包的精确版本或 commit，并与 OSV/GHSA 的受影响版本区间对照判定。用于自有系统或已授权资产的版本确认、漏洞影响面判定、供应链版本确认。触发词：版本指纹、SRI、integrity、精确版本、commit 反查、受影响版本区间、版本到底是不是有洞。
---
---
name: version-pinning
description: 把静态资产指纹（SRI / sha256 / sha1）反查为上游包的精确版本或 commit，并与 OSV/GHSA 的受影响版本区间对照判定。用于自有系统或已授权资产的版本确认、漏洞影响面判定、供应链版本确认。触发词：版本指纹、SRI、integrity、精确版本、commit 反查、受影响版本区间、版本到底是不是有洞。
---

# 版本钉定（version-pinning）

把"这个静态文件到底是哪个版本"从猜测变成可验证事实，再据此判定"这个版本到底受不受某个漏洞影响"。

## 何时用
- 需要确认某系统实际运行的框架/库版本（HTML 里带 `integrity=` 的 SRI、chunk 文件 hash、`?ver=` 参数）；
- 需要判断"低于修复版本号"这种结论是否成立（发行版 backport、自编译分支会让版本号骗人）；
- 需要给一份可复核的"版本 → CVE 影响面"对照清单。

## 铁律
1. **版本号 ≠ 漏洞边界，commit 才是。** `versionEndExcluding` 是"修复版本号"，修复常只 backport 到部分分支；
   发行版包名里的 `-deb11u3` 之类后缀说明补丁已 backport，即使版本号落在受影响区间也可能不可利用。
   只能给三种表述：**精确**（哈希命中唯一上游产物）/ **区间**（能框定 tag 或 commit 范围）/ **未知**（只有 banner）。
   未知时**不许**下"该站存在 XX 漏洞"的结论。
2. **区分边缘层与源站。** CDN/反代（Cloudflare 等）会终结 TLS、改写响应头、替换错误页——
   此时外部指纹拿到的是边缘特征，误判率高到不能支撑结论。此时应改走源站侧证据（镜像 digest、
   `package.json`/lock 文件、构建信息、`/version`、`/health`）。
3. **不主动访问未授权目标。** 本技能只访问上游公共源（unpkg / jsdelivr / npm registry / OSV）；
   对被评估系统的流量，只能在授权范围内进行。

## 用法

```bash
# 1) 已知目标 SRI，反查候选版本中哪个匹配（命中即精确版本）
python3 scripts/sri_match.py --pkg react --file umd/react.production.min.js \
    --match "sha384-<base64>" --candidates 18.2.0,18.3.1,19.0.0

# 2) 只列出各候选版本的哈希（做人工比对 / 建指纹库）
python3 scripts/sri_match.py --pkg react --file umd/react.production.min.js \
    --candidates 18.2.0,18.3.1 --list

# 3) 精确版本 → OSV 漏洞与受影响区间
python3 scripts/sri_match.py --osv npm:lodash@4.17.15
```

脚本细节：
- 逐版本从 unpkg / jsDelivr 取**包内文件字节**重算 sha384(SRI)/sha256/sha1，与目标指纹比对；
  某版本没有该文件（404）会标"取不到"，不中断。
- 退出码：0 命中 / 2 未命中 / 1 运行错误。
- OSV 不可达时（网关限制）会提示改用 NVD/GHSA 网页或平台侧 `cve-search` 技能（`lookup` / `pkg`）。

## 补充指纹来源（都是别人已抓好的公开存量，查它们不产生对目标的流量）
- Certificate Transparency（crt.sh / Censys CT）：出主机名与证书元数据，**不出软件版本**；
- Shodan / Censys / FOFA / ZoomEye 历史指纹：`http.component`、`http.favicon.hash`(MurmurHash3)、
  `http.title`、`ssl.cert`、`tls.version`——注意时效性，且指纹字段可能来自边缘节点；
- 静态文件 hash 库：Retire.js `repository/jsrepository.json`（文件 hash → 版本区间 → CVE 三合一）、
  BlindElephant（按版本建区分性路径库）、fingerprinter（按文件 hash 集合做唯一指纹）。

## 证据链要求（写报告时按这个来）
版本判定依据 → 哈希来源（URL + 取值时间 + 字节长度）→ 精确/区间/未知的表述 → 受影响 CVE 清单
（编号、来源链接、判定依据）→ 缓解/升级建议。**任何一环缺失，结论就降级为"候选"，不写成事实。**
