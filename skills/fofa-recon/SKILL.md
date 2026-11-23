---
name: fofa-recon
description: 用 FOFA 测绘目标资产；默认官方 API，配置 FOFA_POOL_BASE 后自动切换第三方号池
whenToUse: 信息收集阶段拿到单位名/域名/证书等标识、需要铺开互联网资产面、且已配 FOFA key 或号池令牌时
role: recon
enabled: true
---
> **默认官方 API**：不设 `FOFA_POOL_BASE` 时，走 `https://fofa.info/api/v1/search/all`，`FOFA_KEY` 或 `FOFA_KEYS` 填官方 key。
> **第三方号池**：只有设置 `FOFA_POOL_BASE` 才切换；例如 `FOFA_POOL_BASE=https://fofa.ssgonet.com`，此时 `FOFA_KEY` 或 `FOFA_KEYS` 填号池令牌。
> 官方兼容镜像：可设 `FOFA_API_BASE=https://镜像域名`，仍走官方协议。

# FOFA 资产测绘

## 模式与凭据

| 模式 | 触发条件 | 接口 | FOFA_KEY / FOFA_KEYS |
|---|---|---|---|
| 官方（默认） | 未设置 `FOFA_POOL_BASE` | `GET {FOFA_API_BASE}/api/v1/search/all` | 官方 API key |
| 第三方号池 | 设置 `FOFA_POOL_BASE` | `POST {FOFA_POOL_BASE}/api/search` | 号池令牌 |

变量写在 `/state/redteam/.env`：

`.env` 不是数组类型，多 key 用一行逗号分隔（客户端自己拆成列表），或分行写 `FOFA_KEY_1`、`FOFA_KEY_2`：

```bash
# 单 key（兼容旧配置）
FOFA_KEY=...

# 多 key：任选一种写法，客户端自动轮换
FOFA_KEYS=key1,key2,key3
# FOFA_KEY_1=key1
# FOFA_KEY_2=key2

# 可选：官方兼容镜像
# FOFA_API_BASE=https://镜像域名
# 可选：第三方号池；不写就是官方
# FOFA_POOL_BASE=https://fofa.ssgonet.com
```

多 key 轮换规则：

- 当前 key 返回 `401/403/402/429`，或官方返回账号无效/额度不足时，自动切下一个 key；
- `429` 会先按 `2/5/10` 秒退避重试，仍失败再换 key；
- 所有 key 都不可用时停止，不会死循环；
- 日志只打印 `#序号 ...尾号`，不打印完整 key。

号池限制：

- `size` 2~50；
- `page*size <= 60`；
- 每次搜索消耗 1 次号池额度；
- `401` 令牌无效、`403` 额度用完、`429` 限速、`502` 多为 `page*size>60`。

## 使用纪律

1. 先用 `domain=` / `cert=` / `org=` 收窄，不要直接跑宽泛的 `title="login"`。
2. 官方按 1 请求/秒保守执行；号池也保持至少 1 秒间隔。
3. 号池单次查询最多 60 条：默认 `--size 50 --pages 1`，要 60 条用 `--size 10 --pages 6`。
4. 结果缓存在 `/state/redteam/runs/fofa-*.jsonl`，同一查询先看缓存。
5. 按 `(ip, port)` 去重后再写入资产表。

## 客户端

```bash
cat > /state/redteam/runs/fofa_client.py <<'PY'
#!/usr/bin/env python3
"""FOFA 采集：默认官方 API；设置 FOFA_POOL_BASE 后切第三方号池。

模式：
- 默认（未设置 FOFA_POOL_BASE）：
  GET  {FOFA_API_BASE:-https://fofa.info}/api/v1/search/all
  参数 key / qbase64 / size / page / fields
- 第三方（设置 FOFA_POOL_BASE）：
  POST {FOFA_POOL_BASE}/api/search
  Header X-API-Key，JSON {query,page,size}

用法:
  python3 fofa_client.py 'domain="example.com"'
  python3 fofa_client.py 'domain="example.com"' --pages 2 --size 100
  FOFA_POOL_BASE=https://fofa.ssgonet.com python3 fofa_client.py 'domain="example.com"' --pages 1 --size 50
输出:
  /state/redteam/runs/fofa-<slug>.jsonl
"""
import argparse
import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_OFFICIAL_BASE = "https://fofa.info"
FIELDS = "host,ip,port,title,domain,server,protocol"
RETRY_DELAYS = [2, 5, 10]


def _load_dsh_env():
    """/state/redteam/.env 兜底加载：宿主子进程会清洗 KEY/TOKEN 类环境变量。"""
    home = os.environ.get("DSH_HOME") or os.path.join(os.path.expanduser("~"), ".dsh")
    try:
        with open(os.path.join(home, ".env"), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip("'").strip('"'))
    except OSError:
        pass


_load_dsh_env()

def _split_keys(value):
    return [x for x in re.split(r"[,\s;]+", value.strip()) if x]


def load_keys():
    """支持 FOFA_KEYS=key1,key2 / FOFA_KEY_1=... / 单 key FOFA_KEY。"""
    keys = []
    raw = os.environ.get("FOFA_KEYS", "").strip()
    if raw:
        keys.extend(_split_keys(raw))
    indexed = []
    for name, value in os.environ.items():
        m = re.fullmatch(r"FOFA_KEY_(\d+)", name)
        if m and value.strip():
            indexed.append((int(m.group(1)), value.strip()))
    keys.extend(value for _, value in sorted(indexed))
    single = os.environ.get("FOFA_KEY", "").strip()
    if single:
        keys.append(single)
    result = []
    for key in keys:
        if key not in result:
            result.append(key)
    return result


KEYS = load_keys()
KEY_INDEX = 0
KEY = KEYS[0] if KEYS else ""
EXHAUSTED = set()
POOL_BASE = (os.environ.get("FOFA_POOL_BASE") or "").strip().rstrip("/")
OFFICIAL_BASE = (os.environ.get("FOFA_API_BASE") or DEFAULT_OFFICIAL_BASE).strip().rstrip("/")
MODE = "pool" if POOL_BASE else "official"
BASE = POOL_BASE if MODE == "pool" else OFFICIAL_BASE


def key_label(index):
    key = KEYS[index]
    return f"#{index + 1} ...{key[-4:]}" if len(key) >= 4 else f"#{index + 1}"


def advance_key(reason=""):
    global KEY, KEY_INDEX
    if len(KEYS) <= 1:
        return False
    EXHAUSTED.add(KEY_INDEX)
    for _ in range(len(KEYS) - 1):
        index = (KEY_INDEX + 1) % len(KEYS)
        if index not in EXHAUSTED:
            KEY_INDEX = index
            KEY = KEYS[index]
            print(f"[key] {reason + '，' if reason else ''}切换到 {key_label(index)}", file=sys.stderr)
            return True
    return False


def key_exhausted(data):
    """判断当前 key 是否应弃用；普通查询错误不换 key。"""
    if not isinstance(data, dict):
        return False
    if MODE == "official":
        msg = str(data.get("errmsg") or "").lower()
        return bool(data.get("error")) and any(
            token in msg for token in ("-700", "45013", "额度", "次数", "无效", "invalid", "permission", "权限")
        )
    code = data.get("code")
    msg = str(data.get("message") or data.get("msg") or "").lower()
    return code in (401, 403, 402, 429) or any(
        token in msg for token in ("额度", "次数", "无效", "invalid", "permission", "权限", "rate")
    )


def request_json(req, timeout):
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "ignore")
        try:
            return exc.code, json.loads(raw)
        except Exception:
            return exc.code, {"error": True, "errmsg": raw[:200]}
    except Exception as exc:
        return 0, {"error": True, "errmsg": f"{type(exc).__name__}: {exc}"}


def fetch_official(query, page, size, timeout=30):
    qs = urllib.parse.urlencode({
        "key": KEY,
        "qbase64": base64.b64encode(query.encode()).decode(),
        "size": size,
        "page": page,
        "fields": FIELDS,
    })
    req = urllib.request.Request(
        OFFICIAL_BASE + "/api/v1/search/all?" + qs,
        headers={"User-Agent": "redteam-recon/1.0"},
    )
    return request_json(req, timeout)


def fetch_pool(query, page, size, timeout=30):
    body = json.dumps({"query": query, "page": page, "size": size}).encode("utf-8")
    req = urllib.request.Request(
        POOL_BASE + "/api/search",
        data=body,
        method="POST",
        headers={
            "X-API-Key": KEY,
            "Content-Type": "application/json",
            "User-Agent": "redteam-recon-pool/1.0",
        },
    )
    return request_json(req, timeout)


def is_retryable(data):
    if not isinstance(data, dict):
        return False
    if MODE == "official":
        return bool(data.get("error")) and "45012" in str(data.get("errmsg") or "")
    return data.get("code") == 429


def extract_assets(data):
    if MODE == "official":
        rows = data.get("results") or []
        fields = data.get("fields") or FIELDS.split(",")
        assets = []
        for row in rows:
            if isinstance(row, dict):
                assets.append(row)
            elif isinstance(row, (list, tuple)):
                assets.append(dict(zip(fields, row)))
        return assets
    return data.get("assets") or []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("query")
    ap.add_argument("--pages", type=int, default=None, help="页数；官方默认 2，号池默认 1")
    ap.add_argument("--size", type=int, default=None, help="每页条数；官方默认 100，号池默认 50")
    ap.add_argument("--interval", type=float, default=1.0, help="请求最小间隔秒，默认 1.0")
    ap.add_argument("--out", default=None)
    # 兼容旧脚本里的 --pool；现在由 FOFA_POOL_BASE 自动决定模式。
    ap.add_argument("--pool", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()

    if args.pool and MODE != "pool":
        print("[stop] 指定了 --pool，但未配置 FOFA_POOL_BASE", file=sys.stderr)
        return 2

    if not KEYS:
        print("[stop] 未找到 FOFA_KEY / FOFA_KEYS", file=sys.stderr)
        return 2

    if MODE == "pool":
        size = args.size if args.size is not None else 50
        pages = args.pages if args.pages is not None else 1
        if not (2 <= size <= 50):
            print("[stop] 号池 --size 必须在 2..50", file=sys.stderr)
            return 2
        max_pages = 60 // size
        if pages > max_pages:
            print(f"[warn] 号池 page*size 不能超过 60，--pages 从 {pages} 收到 {max_pages}", file=sys.stderr)
            pages = max_pages
    else:
        size = args.size if args.size is not None else 100
        pages = args.pages if args.pages is not None else 2
        if size <= 0 or pages <= 0:
            print("[stop] --size / --pages 必须大于 0", file=sys.stderr)
            return 2

    print(f"[mode] {MODE} base={BASE} keys={len(KEYS)}", file=sys.stderr)

    slug = hashlib.md5(args.query.encode()).hexdigest()[:8]
    out = args.out or f"/state/redteam/runs/fofa-{slug}.jsonl"
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)

    if os.path.exists(out) and os.path.getsize(out) > 0:
        print(f"[cache] {out} 已存在（{os.path.getsize(out)} bytes），如需重拉请先删除", file=sys.stderr)
        return 0

    rows = 0
    last_ts = 0.0
    with open(out, "w", encoding="utf-8") as fh:
        for page in range(1, pages + 1):
            wait = args.interval - (time.time() - last_ts)
            if wait > 0:
                time.sleep(wait)
            last_ts = time.time()

            status, data = 0, None
            max_attempts = len(KEYS) + len(RETRY_DELAYS)
            for attempt in range(max_attempts):
                if MODE == "pool":
                    status, data = fetch_pool(args.query, page, size)
                else:
                    status, data = fetch_official(args.query, page, size)
                if key_exhausted(data) and advance_key("key 不可用或额度耗尽"):
                    continue
                if is_retryable(data) and attempt < len(RETRY_DELAYS):
                    delay = RETRY_DELAYS[attempt]
                    print(f"[retry] 限速，{delay}s 后重试", file=sys.stderr)
                    time.sleep(delay)
                    continue
                break

            if not isinstance(data, dict):
                print(f"[stop] page={page} HTTP={status} 非 JSON 响应", file=sys.stderr)
                break

            if MODE == "official":
                if data.get("error"):
                    print(
                        f"[stop] page={page} HTTP={status} errmsg={data.get('errmsg')}",
                        file=sys.stderr,
                    )
                    break
                total = data.get("size")
                remaining = "-"
            else:
                if data.get("code") != 0:
                    print(
                        f"[stop] page={page} HTTP={status} code={data.get('code')} "
                        f"message={data.get('message') or data.get('msg')}",
                        file=sys.stderr,
                    )
                    break
                total = data.get("total")
                remaining = data.get("remaining_today")

            assets = extract_assets(data)
            print(
                f"[page {page}] total={total} remaining_today={remaining} assets={len(assets)}",
                file=sys.stderr,
            )
            for asset in assets:
                fh.write(json.dumps(asset, ensure_ascii=False) + "\n")
            rows += len(assets)

    print(f"[done] {out} rows={rows}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
```

## 用法

```bash
# 默认官方
python3 /state/redteam/runs/fofa_client.py 'domain="example.com"'

# 官方镜像（同一个协议，只换 base）
FOFA_API_BASE=https://镜像域名 python3 /state/redteam/runs/fofa_client.py 'domain="example.com"'

# 第三方号池（在 .env 里设 FOFA_POOL_BASE 后，客户端自动切）
python3 /state/redteam/runs/fofa_client.py 'domain="example.com"' --pages 1 --size 50
```

结果：

```text
/state/redteam/runs/fofa-<slug>.jsonl
```
