# Docker 部署

本文档描述如何用 Docker / Docker Compose 部署 V2Board 面板。**完全容器化** —— MySQL、Redis、面板应用全部跑在容器内,不依赖任何外部服务。**镜像在 GitHub Actions 预编译并发布到 GHCR,VPS 只 `docker pull`**,不在本机编译(适合 1C1G 等弱鸡 VPS)。

> 项目结构、运行时 quirks、`config/v2board.php` 的运行时生成机制等,见 [`AGENTS.md`](./AGENTS.md)。本文档只覆盖部署。

## 架构概览

`docker compose up` 一次性起三个 service:

| service | 镜像 | 作用 |
|---|---|---|
| `v2board` | `ghcr.io/jackxunkun163/v2board:latest`(CI 预编译) | 面板应用;容器内 supervisor 编排 nginx + php-fpm + horizon + crond |
| `mysql` | `mysql:5.7` | 业务数据库,持久化到命名 volume |
| `redis` | `redis:7-alpine` | 缓存 / 队列 / Session,持久化到命名 volume |

`v2board` 通过 `depends_on` 等 MySQL/Redis 健康检查通过后再启动,entrypoint 自动等待并初始化。

容器内进程编排(supervisord):

| 进程 | 作用 |
|---|---|
| `nginx` | 监听容器 :80,反代到 php-fpm,服务 `public/` |
| `php-fpm` | 执行 Laravel 应用 |
| `php artisan horizon` | 队列 worker(`pm2.yaml` 在容器内由 supervisor 替代) |
| `crond` | 每分钟跑 `php artisan schedule:run` |

## 前置条件

- 一台 Linux VPS(推荐 Ubuntu 22.04+ / Debian 12+),已 root 或 sudo
- 公网 IP,80/443 端口未占用
- (可选,要 HTTPS 必备)一个 A 记录指向该 IP 的域名
- VPS 至少 1 vCPU / 1 GB RAM(只跑容器,不编译,1G 够用)

## 文件清单

**VPS 上部署只需要这 2 个文件**:

| 文件 | 作用 |
|---|---|
| `docker-compose.yml` | 定义 v2board + mysql + redis 三个 service、volume、environment |
| `.env.docker` | 你填的密码 / 邮箱 / 站点 URL |

应用代码、`Dockerfile`、entrypoint 脚本、`install.sql` 全部在 GHCR 镜像里 —— VPS 不需要 clone 整个仓库,也不需要本地编译。

> 仓库内的 `Dockerfile` / `docker/` / `.github/workflows/docker-publish.yml` 是给 GitHub Actions 构建镜像用的,部署时用不到。

## 快速开始

下面命令假设全新 Ubuntu VPS。

### 1. 安装 Docker

```bash
apt update && apt install -y curl ufw ca-certificates
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
docker version && docker compose version   # 验证
```

### 2. 拉取部署文件

只需要两个文件,直接从仓库 raw 下载:

```bash
mkdir -p /opt/v2board && cd /opt/v2board
curl -O https://raw.githubusercontent.com/jackxunkun163/v2board/master/docker-compose.yml
curl -O https://raw.githubusercontent.com/jackxunkun163/v2board/master/.env.docker.example
```

### 3. 配置环境

```bash
cp .env.docker.example .env.docker
nano .env.docker
```

必改字段:

| 字段 | 说明 |
|---|---|
| `APP_URL` | 站点完整 URL,如 `https://v2board.example.com`。没域名用 `http://<vps-ip>` |
| `DB_PASSWORD` | v2board 业务库密码(强) |
| `DB_ROOT_PASSWORD` | MySQL root 密码(强) |
| `ADMIN_EMAIL` | 首次启动建管理员用 |
| `ADMIN_PASSWORD` | 至少 8 位 |

`DB_HOST` / `REDIS_HOST` 已在 compose 里写死为 service 名,不用在 `.env.docker` 配。

### 4. 拉镜像并启动

```bash
docker compose --env-file .env.docker pull
docker compose --env-file .env.docker up -d
```

三个容器会按 `mysql → redis → v2board` 顺序启动。

> 首次部署如果 `pull` 报 `not found` / `unauthorized`:
> - **CI 还没跑完**:浏览器打开 `https://github.com/jackxunkun163/v2board/actions` 看进度(约 5-15 分钟),绿勾后再 pull
> - **镜像可见性是 private**:浏览器打开 `https://github.com/users/jackxunkun163/packages/container/v2board/settings` → 拉到底 **Danger Zone → Change visibility → Public**;或用 PAT 在 VPS 上 `docker login ghcr.io`

### 5. 看日志确认就绪

```bash
docker compose --env-file .env.docker logs -f v2board
```

等到出现 `[init-db] Admin user created: <你的邮箱>` 即完成,`Ctrl+C` 退出。

### 6. 验证

```bash
curl -I http://localhost:8080/    # 应 200
```

## 配置详解:`.env.docker`

| 变量 | 默认 | 说明 |
|---|---|---|
| `V2BOARD_IMAGE` | `ghcr.io/jackxunkun163/v2board:latest` | 面板镜像。fork 后再 fork 时改这里;也可固定到 `sha-xxxxxxx` 锁版本 |
| `V2BOARD_PORT` | `8080` | 宿主机映射端口。套反代后通常不暴露公网 |
| `APP_URL` | — | 站点完整 URL,**必须**改成实际域名/IP |
| `APP_ENV` | `production` | 生产保持 production |
| `APP_DEBUG` | `false` | 生产保持 false |
| `APP_KEY` | 空(自动) | JWT 签名密钥。留空 = entrypoint 首次启动生成并缓存到 `storage` volume(跨容器重建稳定)。需要多副本共享时手动填同一个值 |
| `DB_DATABASE` | `v2board` | 业务库名 |
| `DB_USERNAME` / `DB_PASSWORD` | — | 业务账号 |
| `DB_ROOT_PASSWORD` | — | MySQL root,用于 mysqldump 备份 |
| `REDIS_PASSWORD` | 空 | 想开 Redis Auth 需同时改 `docker-compose.yml` 的 redis 启动命令 |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` | 空 | 首次启动建管理员;之后改密码走面板 |

`.env.docker` 含明文密码,**自行妥善保管**(curl 下来的部署目录不会被任何 git 跟踪)。

## HTTPS(Caddy 反代 + 自动证书)

推荐用 Caddy,3 行配置自动申请并续期 Let's Encrypt 证书。

新建 `/opt/caddy/docker-compose.yml`:

```yaml
services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    network_mode: host
volumes:
  caddy-data:
  caddy-config:
```

`/opt/caddy/Caddyfile`(把域名换成你的):

```caddy
v2board.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

```bash
cd /opt/caddy && docker compose up -d
```

首次访问域名时 Caddy 自动签证书,等 10-30 秒。

## 防火墙

```bash
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

不要把 `V2BOARD_PORT`(默认 8080)暴露公网,只让反代访问。要本机调试就改 `docker-compose.yml` 把 `ports` 绑到 `127.0.0.1:8080:80`。

## 首次登录

- 用户中心:`https://<域名>/`
- 后台路径:`https://<域名>/<secure_path>`,默认 `secure_path = hash('crc32b', APP_KEY)`

查看具体路径(`php -r` 不 bootstrap Laravel,要用 `artisan tinker`):

```bash
docker compose --env-file .env.docker exec v2board \
    php artisan tinker --execute 'echo hash("crc32b", config("app.key"));'
```

或在管理员登录后,「主题配置 → 安全路径」修改。首次登录后建议立刻在用户中心改 `ADMIN_PASSWORD`。

## 日常运维

所有命令在 `/opt/v2board` 下执行,且需要带 `--env-file .env.docker`(或导出为 shell 变量)。

### 日志

```bash
# 面板(nginx + php-fpm + horizon + cron 混在一起)
docker compose --env-file .env.docker logs -f v2board

# 单独的 Laravel 应用日志(容器内)
docker compose --env-file .env.docker exec v2board tail -f storage/logs/laravel.log

# MySQL / Redis
docker compose --env-file .env.docker logs -f mysql
docker compose --env-file .env.docker logs -f redis
```

### 重启服务

```bash
# 整套
docker compose --env-file .env.docker restart

# 只重启面板
docker compose --env-file .env.docker restart v2board

# 仅重启队列(等同于 horizon:terminate,Horizon 会自动拉起)
docker compose --env-file .env.docker exec v2board php artisan horizon:terminate
```

### 升级面板

分两种情况,通常只需要第 1 种。

**1. 升级面板镜像(代码有更新)** —— 推 master 后 GitHub Actions 自动重建镜像,VPS 拉新版即可:

```bash
cd /opt/v2board
docker compose --env-file .env.docker pull v2board
docker compose --env-file .env.docker up -d
docker compose --env-file .env.docker exec v2board php artisan v2board:update
```

`v2board:update` 会跑 `database/update.sql` 增量更新 + 重启 horizon。

> CI 构建需要几分钟。如果 `pull` 拉到的还是旧镜像,等几分钟(GitHub Actions 页看进度)再 pull。

**2. 升级 compose 配置(`docker-compose.yml` 有改动)** —— 偶尔需要,比如改了端口映射、加了新 service:

```bash
cd /opt/v2board
curl -O https://raw.githubusercontent.com/jackxunkun163/v2board/master/docker-compose.yml
docker compose --env-file .env.docker up -d
```

### 备份与恢复

**数据库**:

```bash
source .env.docker
docker exec v2board-mysql mysqldump -u root -p"$DB_ROOT_PASSWORD" \
    --single-transaction v2board > backup-$(date +%F).sql

# 恢复
docker exec -i v2board-mysql mysql -u root -p"$DB_ROOT_PASSWORD" v2board < backup-YYYY-MM-DD.sql
```

**运行时配置与文件**(命名 volume):

```bash
# 备份
tar czf v2board-state-$(date +%F).tgz \
    /var/lib/docker/volumes/v2board_v2board-storage/_data \
    /var/lib/docker/volumes/v2board_v2board-config/_data \
    /var/lib/docker/volumes/v2board_v2board-mysql/_data \
    /var/lib/docker/volumes/v2board_v2board-redis/_data

# 恢复:解压回原路径,然后 docker compose restart
```

`config` volume 里包含运行时生成的 `config/v2board.php`(面板所有后台设置),**这是必须备份的**。

## 故障排查

| 症状 | 排查 |
|---|---|
| `docker compose pull` 报 `not found` / `unauthorized` | CI 还没构建完,或镜像可见性还是 private。看 `https://github.com/jackxunkun163/v2board/actions` 状态;绿勾后到 Packages 设置页改 public |
| `docker compose logs -f v2board` 立即返回空 | v2board 容器没创建。先确认 `up -d` 跑过,`docker compose ps -a` 应能看到 v2board |
| 容器一直 restart | `docker compose logs v2board` 看启动报错。最常见是 DB/Redis 连不上 |
| 登录后立即被踢回登录页 / 反复登录 | `APP_KEY` 变了导致签发的 JWT 全部失效。`docker compose exec v2board grep APP_KEY .env` 检查;跨 `down && up` 是否稳定。entrypoint 已把 APP_KEY 缓存到 storage volume,若仍异常检查 storage volume 是否被清掉 |
| 首次启动 "Waiting for MySQL" 等 60 次后 WARNING,但 init-db 仍成功 | mariadb-client 的 `mysqladmin ping` 对 mysql:5.7 有认证假阴性,entrypoint 已改用 PHP PDO 探测。若仍出现,检查 `.env.docker` 里 `DB_PASSWORD` 是否含 `$`(compose 会插值,需写成 `$$`)|
| 后台 404 / 路径不对 | `secure_path` 算错,用上面的 `artisan tinker` 命令重新查 |
| 改了后台配置不生效 | 容器内已 `config:cache`;面板保存时会自动重刷 |
| horizon 不工作 | `docker compose exec v2board php artisan horizon` 看前台输出;通常是 Redis 连不上 |
| 502 / 504 | php-fpm 挂了或超时。检查 `storage/logs/laravel.log` 和容器日志 |
| 时区错乱 | 容器内 Laravel 用 `Asia/Shanghai`(见 `config/app.php`),不依赖宿主时区 |

进容器手动排查:

```bash
docker compose --env-file .env.docker exec v2board sh
# 容器内可用 php artisan tinker / mysql / redis-cli
```

> 注意:进 v2board 容器用 `mysql` / `redis-cli` 时,默认走 socket/localhost 会失败。用 `mysql -h mysql -u root -p` 或 `redis-cli -h redis`(走 service 名)。

## 后端节点对接

面板跑起来只完成了订阅/订单/用户管理。真正代理流量需要另起后端节点,推荐用本分支对应的 [wyx2685/V2bX](https://github.com/wyx2685/V2bX):

1. 在面板后台「节点管理」添加节点,记下生成的 API 接口地址与 token
2. 按 V2bX 仓库自身文档在节点机部署,回连面板 API

后端的部署属于另一个项目,不在本文档范围。

## 反向参考

- 项目结构、运行时 quirks、控制器约定、auth middleware 等 → [`AGENTS.md`](./AGENTS.md)
- 原版迁移流程 → [`readme.md`](./readme.md)
