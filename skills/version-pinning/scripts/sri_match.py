#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sri_match.py —— 静态资产哈希 → 精确上游版本/commit 反查 + OSV 漏洞区间对照

用途（授权范围内的资产评估 / 自有系统自查 / 供应链版本确认）：
  1) 已知目标公开静态资源的 SRI（sha384-...）或 sha256/sha1 十六进制指纹，
     反查它来自哪个上游包的哪个精确版本（unpkg / jsDelivr 逐版本取文件重算哈希比对）。
  2) 拿到精确版本后，查 OSV/GHSA 的受影响版本区间，输出"受影响/不受影响"判定。
  3) 只访问上游公共源（unpkg / jsdelivr / registry.npmjs.org / api.osv.dev），
     不访问被评估目标本身。

示例：
  # 列出候选版本的哈希并与目标 SRI 比对
  python3 sri_match.py --pkg react --file umd/react.production.min.js \
      --match "sha384-<base64>" --candidates 18.2.0,18.3.1,19.0.0

  # 只打印各候选版本的哈希（拿去做人工比对）
  python3 sri_match.py --pkg react --file umd/react.production.min.js \
      --candidates 18.2.0,18.3.1 --list

  # 精确版本 → OSV 漏洞清单（含受影响区间）
  python3 sri_match.py --osv npm:react@18.2.0
  python3 sri_match.py --osv npm:lodash@4.17.15

退出码：0 命中 / 2 未命中 / 1 运行错误。
"""
import argparse
import base64
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request

UA = {"User-Agent": "version-pinning/1.0 (authorized asset assessment)"}
# 常见上游镜像，按可用性依次尝试
CDN_TEMPLATES = [
    "https://unpkg.com/{pkg}@{ver}/{path}",
    "https://cdn.jsdelivr.net/npm/{pkg}@{ver}/{path}",
]


def fetch(url, timeout=30, retries=3):
    """带重试的 GET（走系统代理环境变量；代理抖动常见）。"""
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (404, 451):
                return None
            last = e
        except Exception as e:  # URLError / timeout / ssl
            last = e
        time.sleep(1.5 * (attempt + 1))
    raise RuntimeError("fetch failed: %s (%s)" % (url, last))


def hashes(data: bytes):
    """返回 (sha384-SRI, sha256-hex, sha1-hex)。"""
    sri = "sha384-" + base64.b64encode(hashlib.sha384(data).digest()).decode()
    return sri, hashlib.sha256(data).hexdigest(), hashlib.sha1(data).hexdigest()


def match_normalize(target: str):
    """把 --match 归一为可比较集合。注意：SRI 的 base64 部分大小写敏感，不能整体 lower。"""
    t = target.strip()
    out = set()
    if t.lower().startswith("sha384-"):
        out.add(t)          # SRI：保持原样（大小写敏感）
        out.add(t.lower())
    else:
        h = t.lower()
        out.add(h)
        out.add(h.upper())
        out.add("sha256-" + h)
        out.add("sha1-" + h)
    return out


def fetch_pkg_file(pkg, ver, path):
    for tpl in CDN_TEMPLATES:
        url = tpl.format(pkg=pkg, ver=ver, path=path)
        try:
            data = fetch(url)
        except RuntimeError:
            continue
        if data is not None:
            return url, data
    return None, None


def cmd_match(args):
    cands = [v.strip() for v in args.candidates.split(",") if v.strip()]
    if not cands:
        print("需要 --candidates 版本列表", file=sys.stderr)
        return 1
    target = match_normalize(args.match) if args.match else None
    rows, hit = [], None
    for ver in cands:
        url, data = fetch_pkg_file(args.pkg, ver, args.file)
        if data is None:
            rows.append((ver, "取不到该版本文件", "", "", ""))
            continue
        sri, s256, s1 = hashes(data)
        status = ""
        if target:
            cand = {"sha384-" + sri.split("-", 1)[1], s256, s1}
            ok = any(t in cand or t == sri for t in target)
            status = "★命中" if ok else "不匹配"
            if ok and hit is None:
                hit = (ver, url)
        rows.append((ver, sri, s256[:16] + "…", s1[:16] + "…", status))
    w = "{:<12} {:<56} {:<18} {:<18} {}".format("版本", "SRI(sha384)", "sha256", "sha1", "判定")
    print(w)
    print("-" * len(w))
    for r in rows:
        print("{:<12} {:<56} {:<18} {:<18} {}".format(*[str(x) for x in r]))
    if hit:
        print("\n精确版本: %s  (来源 %s)" % hit)
        print("下一步: python3 sri_match.py --osv npm:%s@%s" % (args.pkg, hit[0]))
        return 0
    print("\n未命中：目标指纹不属于所列候选版本（扩大候选区间，或改用 commit 级候选）")
    return 2


def cmd_list(args):
    for ver in [v.strip() for v in args.candidates.split(",") if v.strip()]:
        url, data = fetch_pkg_file(args.pkg, ver, args.file)
        if data is None:
            print("%s\t取不到" % ver)
            continue
        sri, s256, s1 = hashes(data)
        print("%s\t%s\t%s\t%s\t%s" % (ver, sri, s256, s1, url))


def cmd_osv(args):
    spec = args.osv
    if "@" not in spec or ":" not in spec:
        print("--osv 格式应为 npm:<pkg>@<version>", file=sys.stderr)
        return 1
    eco, rest = spec.split(":", 1)
    name, ver = rest.rsplit("@", 1)
    q = {"package": {"name": name, "ecosystem": eco}, "version": ver}
    body = json.dumps(q).encode()
    req = urllib.request.Request("https://api.osv.dev/v1/query", data=body,
                                 headers=dict(UA, **{"Content-Type": "application/json"}),
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:
        print("OSV 查询失败（网络不可达或被网关拦截）：%s" % e, file=sys.stderr)
        print("替代：用平台侧 cve-search 技能（lookup / pkg）查同一包，或直接查 NVD/GHSA 网页。", file=sys.stderr)
        return 1
    vulns = data.get("vulns", [])
    if not vulns:
        print("%s@%s：OSV 未返回已知漏洞记录（不等于无漏洞，仍需看精确 commit 与配置）" % (name, ver))
        return 0
    for v in vulns:
        ids = ", ".join([v.get("id", "")] + [a for a in v.get("aliases", [])])
        affected = []
        for a in v.get("affected", []):
            ev = a.get("events", [])
            txt = ", ".join("%s=%s" % (e.get("introduced") or e.get("fixed") or e.get("last_affected") or "?",
                                       "fixed" if "fixed" in e else "introduced" if "introduced" in e else "last_affected")
                            for e in ev)
            affected.append("%s %s" % (txt, "[%s]" % a.get("database_specific", {}).get("source", "") if a.get("database_specific") else ""))
        print("- %s | %s" % (ids, v.get("summary", "").strip().replace("\n", " ")[:160]))
        for a in affected:
            print("    区间: %s" % a.strip())
        refs = [r.get("url") for r in v.get("references", []) if r.get("url")][:3]
        if refs:
            print("    参考: %s" % " ; ".join(refs))
    return 0


def main():
    ap = argparse.ArgumentParser(description="静态资产哈希 → 精确上游版本/commit 反查 + OSV 区间对照")
    ap.add_argument("--pkg", help="上游包名（npm/pypi 等）")
    ap.add_argument("--file", help="包内文件路径，如 umd/react.production.min.js")
    ap.add_argument("--candidates", default="", help="候选版本，逗号分隔")
    ap.add_argument("--match", default="", help="目标 SRI(sha384-...) 或 sha256/sha1 十六进制")
    ap.add_argument("--list", action="store_true", help="只列各候选版本的哈希")
    ap.add_argument("--osv", default="", help="查 OSV，格式 npm:<pkg>@<version>")
    args = ap.parse_args()
    if args.osv:
        return cmd_osv(args)
    if not args.pkg or not args.file or not args.candidates:
        ap.error("需要 --pkg --file --candidates（或用 --osv）")
    if args.list and not args.match:
        return cmd_list(args)
    return cmd_match(args)


if __name__ == "__main__":
    sys.exit(main())
