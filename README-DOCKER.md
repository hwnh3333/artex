# 老魏二改 ARTEX · Docker 部署

这是把 `ARTEX-老魏二改带知识库-linux-amd64` 直接容器化的版本，不依赖宿主机装 PostgreSQL / Python / JDK。

## 1. 已合并的内容

| 来源 | 内容 | 处理 |
|---|---|---|
| 老魏 | 主程序 `artex`、13 个主技能、34 个 redteam md、知识库 448 条、POC 文件、nuclei 模板、Linux 工具 | 作为底座 |
| 菠菜 | 老魏知识库没有的 **52 条** POC 记录 | 已并入 `redteam/knowledge.db`，现 **500 条**；52 条记录里的 46 个 POC 文件与老魏现有目录逐文件 SHA256 相同，所以没有复制重复文件 |
| 你的技能 | 17 个主技能 + 35 个 `SKILL.md`（34 个 redteam 技能 + `redteam-artex-compat`） | 已并入 `skills/`，现 **52 个技能目录**；`redteam-kit-host-notes`（Windows 专用）已移除 |
| 老魏工具 | fscan、gogo、subfinder、dnsx、httpx、katana、naabu、ksubdomain、chisel、frp、suo5 | 只保留 Linux 二进制 |
| 新增 Linux 工具 | nuclei 3.11.1、ffuf 2.3.0、gospider 1.1.6、jadx 1.5.6、cfr 0.152、massdns | 官方 Release 下载，nuclei/ffuf 校验 SHA256 |
| 排除 | Behinder/Godzilla/AntSword GUI、Windows JDK、Windows exe、oneforall 旧依赖、个人 `runs/`、VPS 私钥、hashcat/john | 非 Linux 或与技能纪律冲突 |

技能可见性另外导出到 `redteam/visibility.sql`（从 VM 的 242 条记录生成，按 agent key 绑定，不写死 ID）。首次启动会自动应用；`defaults.sql` 会额外给内置 agent 补默认行，所以数据库里实际行数会多于 242。

## 2. 快速启动

```bash
cd ARTEX-老魏二改带知识库-linux-amd64
cp .env.example .env
# 编辑 .env，至少改 POSTGRES_PASSWORD
docker compose up -d --build
```

打开 `http://服务器IP:8787`，首次访问 `/setup` 设置登录密码。

健康检查：

```bash
curl -fsS http://127.0.0.1:8787/api/health
docker compose ps
```

## 3. 目录与持久化

- `./state` 是唯一持久目录（bind mount 到容器 `/state`）。
- 首次启动会把镜像里的 `skills/`、`redteam/` 播种到 `./state`；后续重启只补缺失文件，不覆盖已有 `knowledge.db`、`.env`、用户改过的技能。
- PostgreSQL 数据在 compose 的 `pgdata` volume。
- 备份：

```bash
tar czf artex-state-$(date +%F).tgz state
docker run --rm -v artex-oldwei_pgdata:/data -v "$PWD":/backup alpine \
  tar czf /backup/artex-pg-$(date +%F).tgz -C /data .
```

## 4. 工具位置

容器内统一在 `/state/redteam/toolkit`，`/usr/local/bin` 有软链：

```text
fscan gogo subfinder dnsx httpx pd-httpx katana naabu ksubdomain
chisel frpc frps suo5 nuclei ffuf gospider massdns jadx cfr
```

Python 工具在 `/app/.venv/bin`（`impacket-*`、`sqlmap`、`dirsearch`、`pypykatz`）。`netexec` 默认不装：它依赖 git 版 `certipy-ad`，pip 解析会因包名不一致失败；需要时把 `.env` 的 `INSTALL_NETEXEC` 设为 1 后重建，构建日志会明确提示成败。Java 工具用 `openjdk-17-jre-headless`，无 GUI。

## 5. 架构

- 默认构建 `linux/amd64`，当前包内只有 `artex-amd64`。
- Dockerfile 已支持 `TARGETARCH`；要构建 `linux/arm64`，把老魏的 `artex-arm64` 放到本目录后：

```bash
./build-image.sh arm64
```

没有 `artex-arm64` 时脚本会拒绝构建，避免生成一个跑不起来的镜像。工具侧目前只有 `fscan_linux_arm64`、`gogo_linux_arm64` 是 arm64；其他扫描器需要按需补 arm64 Release。

## 6. 首次默认配置

`docker-entrypoint.sh` 会等数据库就绪后执行一次：

- `defaults.sql`：老魏包的破甲开关、预设、拦截规则；
- `redteam/visibility.sql`：技能对各 agent 的可见性。

不想自动应用时在 `.env` 设 `APPLY_DEFAULTS=0`。

## 7. 常用运维

```bash
docker compose logs -f artex
docker compose restart artex
docker compose down              # 保留 state 与 pgdata
docker compose down -v           # 连数据库一起删（谨慎）
```

回滚技能/知识库：直接替换 `state/skills`、`state/redteam/knowledge.db` 后 `docker compose restart artex`。

## 8. 合并校验

`redteam/merge-spinach-report.json` 记录了 52 条新增 POC 的 code/title/category/verified；`poc_merge_log` 表记录来源包。知识库自检：

```bash
sqlite3 state/redteam/knowledge.db \
  "select count(*) from poc; select count(*) from poc_fts; pragma integrity_check;"
# 预期 500 / 500 / ok
```

## 9. GitHub Actions 构建（方案 A）

仓库只提交代码、技能和脚本；`artex-amd64`、`redteam/`（含 knowledge.db / pocs / toolkit）、`nuclei-templates/` 打包成一个 Release 资产，workflow 构建时下载并校验 SHA256。

### 9.1 打包并上传资产

```bash
./pack-redteam-assets.sh
# 输出 ../artex-redteam-assets.tar.gz 和 .sha256
```

在 GitHub 仓库新建 Release（例如 tag `assets-20261118`），上传 `artex-redteam-assets.tar.gz`，然后把 `.github/workflows/build-docker.yml` 里的 `ASSET_URL`、`ASSET_SHA256` 改成实际值并提交。

### 9.2 运行

仓库 **Actions → build-docker → Run workflow**。首次构建会：

1. 下载并校验 Release 资产；
2. `docker buildx build --platform linux/amd64 --push`；
3. 推送到 `ghcr.io/hwnh3333/artex:latest` 和 `:sha-<短 commit>`。

首次推送后到 GitHub 的 **Packages** 页面把镜像可见性设为 public（如需要）。

### 9.3 限制与注意

- 只用 `linux/amd64`：老魏包没有 `artex-arm64` 主程序。
- GitHub 单文件 100MB 硬限制，所以必须用 Release 资产，不能把 toolkit 直接提交。
- `ubuntu-latest` 约 14GB 可用磁盘，本镜像峰值约 5GB，能构建；job 超时设了 60 分钟。
- 资产更新后（例如换知识库）重新打包、重新上传、更新 SHA256 即可。

### 9.4 直接用 GHCR 镜像运行

仓库里没有 `artex-amd64` / `redteam/` / `nuclei-templates/` 这些大文件，**不要**在仓库里直接 `docker compose up --build`。用构建好的镜像：

```bash
docker pull ghcr.io/hwnh3333/artex:latest
cp .env.example .env
# 编辑 .env：
#   POSTGRES_PASSWORD=改成强密码
#   ARTEX_IMAGE=ghcr.io/hwnh3333/artex
#   ARTEX_TAG=latest
docker compose pull artex
docker compose up -d --no-build
```

镜像地址：`ghcr.io/hwnh3333/artex:latest`

