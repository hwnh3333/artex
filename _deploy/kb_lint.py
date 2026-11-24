#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ARTEX 武器库只读体检（KB-POLICY.md v1.0）

默认只扫描 id >= 551 的新数据，老魏包自带条目不动。
不写库、不改文件，只输出报告。

用法:
  python3 kb_lint.py --db /state/redteam/knowledge.db
  python3 kb_lint.py --db ./knowledge.db --since-id 551 --json
  python3 kb_lint.py --db ./knowledge.db --all      # 连老数据一起看（仍只读）
"""

import argparse
import json
import re
import sqlite3
import sys

CATEGORIES = {
    "info-leak", "auth-bypass", "unauthorized", "rce", "recon",
    "methodology", "weak-password", "file-upload", "app-audit",
    "frontend-reverse", "env", "tunnel", "waf", "path-traversal",
    "ssrf", "sqli", "deserialization", "privesc", "protocol", "other",
}
SEVERITIES = {"critical", "high", "medium", "low", "info"}

CODE_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{7,79}$")
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
CJK_RE = re.compile(r"[\u4e00-\u9fff]")
IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
DOMAIN_RE = re.compile(r"\b[a-z0-9-]+(?:\.[a-z0-9-]+)+\.[a-z]{2,}\b", re.I)
SECRET_RES = [
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{12,}"),
    re.compile(r"\b(?:password|passwd|pwd)\s*[:=]\s*(?!\{|\$|%|\*|<)(\S{4,})", re.I),
    re.compile(r"\b(?:token|apikey|api_key|secret)\s*[:=]\s*(?!\{|\$|%|\*|<)([A-Za-z0-9_\-]{16,})", re.I),
]


def issues_for(row):
    """返回 [(level, code, msg)]"""
    out = []

    def add(level, code, msg):
        out.append((level, code, msg))

    code = (row["code"] or "").strip()
    category = (row["category"] or "").strip().lower()
    severity = (row["severity"] or "").strip().lower()
    verified = int(row["verified"] or 0)
    note = (row["verified_note"] or "").strip()
    usage = (row["usage"] or "").strip()
    content = (row["content"] or "").strip()
    component = (row["component"] or "").strip()
    title = (row["title"] or "").strip()

    # G4 code
    if not CODE_RE.match(code):
        add("P0", "G4", "code 不符合命名规范（小写/长度/字符）")
    if CJK_RE.search(code):
        add("P0", "G4", "code 含中文")
    if IPV4_RE.search(code) or DOMAIN_RE.search(code):
        add("P0", "G4", "code 含 IP/域名，不可复用")
    # G1 category
    if not category or category == "other":
        add("P0", "G1", "category 为空或 other")
    elif category not in CATEGORIES:
        add("P1", "G1", f"category 不在枚举内: {category}")
    # G2 来源
    if not (row["engagement_id"] or row["engagement_name"]):
        add("P0", "G2", "缺 engagement")
    if not (row["asset_target"] or "").strip():
        add("P0", "G2", "缺 asset_target")
    # G3 证据
    if verified and len(note) < 40:
        add("P0", "G3", "verified=1 但 verified_note 少于 40 字")
    if verified and not DATE_RE.search(note):
        add("P1", "G3", "verified_note 缺日期")
    if verified and re.search(r"^(已验证|成功|可打|实测可用)[。.]?$", note):
        add("P0", "G3", "verified_note 是空泛结论")
    # G5 可复现
    if not usage and not content:
        add("P0", "G5", "usage 与 content 都为空，无复现载体")
    # G6 敏感值
    blob = " ".join([code, title, note, usage[:2000], content[:4000]])
    for rx in SECRET_RES:
        if rx.search(blob):
            add("P0", "G6", "疑似含真实凭据/私钥/token")
            break
    # 字段完整性
    if not component:
        add("P1", "F", "缺 component")
    if not (row["versions"] or "").strip():
        add("P1", "F", "缺 versions")
    if not severity:
        add("P1", "F", "缺 severity")
    elif severity not in SEVERITIES:
        add("P1", "F", f"severity 非法: {severity}")
    if len(title) > 80:
        add("P2", "F", "title 超过 80 字")
    if not (row["description"] or "").strip():
        add("P1", "F", "缺 description")
    if not (row["tags"] or "").strip():
        add("P2", "F", "缺 tags")
    return out


def semantic_dupes(rows):
    seen = {}
    dup = {}
    for r in rows:
        cve = (r["cve"] or "").strip().lower()
        comp = (r["component"] or "").strip().lower()
        cat = (r["category"] or "").strip().lower()
        ver = (r["versions"] or "").strip().lower()
        if not comp or not cat:
            continue
        key = (cat, comp, cve) if cve else (cat, comp, ver)
        if key in seen:
            dup.setdefault(key, [seen[key]]).append(r["id"])
        else:
            seen[key] = r["id"]
    return dup


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="/state/redteam/knowledge.db")
    ap.add_argument("--since-id", type=int, default=551)
    ap.add_argument("--all", action="store_true", help="包含老数据（仍只读）")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--limit", type=int, default=200)
    args = ap.parse_args()

    conn = sqlite3.connect("file:%s?mode=ro" % args.db, uri=True)
    conn.row_factory = sqlite3.Row
    where, params = ("", ())
    if not args.all:
        where, params = ("WHERE id >= ?", (args.since_id,))
    rows = conn.execute(
        "SELECT id, code, title, category, severity, verified, verified_note, "
        "usage, content, component, versions, cve, description, tags, "
        "engagement_id, engagement_name, asset_target, created_at "
        "FROM poc %s ORDER BY id" % where, params).fetchall()

    dup = semantic_dupes(rows)
    findings = []
    for r in rows:
        iss = issues_for(r)
        if iss:
            findings.append({"id": r["id"], "code": r["code"], "issues": iss})
        elif r["id"] in [x for v in dup.values() for x in v]:
            findings.append({"id": r["id"], "code": r["code"],
                             "issues": [("P1", "G4", "语义重复")]})

    counts = {"P0": 0, "P1": 0, "P2": 0}
    for f in findings:
        for lvl, _, _ in f["issues"]:
            counts[lvl] += 1

    if args.json:
        print(json.dumps({
            "db": args.db, "since_id": args.since_id,
            "scanned": len(rows), "flagged": len(findings),
            "counts": counts, "findings": findings[:args.limit],
            "duplicates": {str(k): v for k, v in dup.items()},
        }, ensure_ascii=False, indent=2))
    else:
        print("== ARTEX KB lint ==")
        print("db=%s since_id=%s scanned=%d flagged=%d" % (
            args.db, args.since_id, len(rows), len(findings)))
        print("P0=%d P1=%d P2=%d" % (counts["P0"], counts["P1"], counts["P2"]))
        if dup:
            print("\n-- 语义重复 --")
            for k, v in list(dup.items())[:20]:
                print("  %s -> %s" % ("/".join(k), ",".join(map(str, v))))
        if findings:
            print("\n-- 条目 --")
            for f in findings[:args.limit]:
                tags = "; ".join("%s:%s %s" % (l, c, m) for l, c, m in f["issues"])
                print("  #%s %s | %s" % (f["id"], f["code"][:60], tags))
        else:
            print("\n无违规条目。")

    conn.close()
    return 1 if counts["P0"] else 0


if __name__ == "__main__":
    sys.exit(main())
