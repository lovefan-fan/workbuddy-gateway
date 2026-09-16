# Docker / Docker Compose 部署

本目录提供 workbuddy-gateway 的容器化部署，无需在宿主机安装 Go 或配置编译环境。

- `Dockerfile` —— 多阶段构建（golang → alpine），产出约 20 MB 的静态单二进制镜像
- `docker-compose.yml` —— 编排 gateway / login / cli 三个入口
- `docker/entrypoint.sh` —— 权限修正 + 环境变量到 CLI 参数翻译 + 降权运行
- `.env.example` —— 可配置项模板

---

## 一、快速开始

### 1. 首次扫码登录

登录是**交互式**的，必须用 `docker compose run`（不能 `up`），以便在终端看到 ASCII 二维码：

```bash
# 国内站：微信 / 企业微信扫码
docker compose run --rm login

# 国际站：需在浏览器内完成登录
docker compose run --rm login -intl

# 多账号：指定不同凭据文件名，或直接放进 data/auths/ 后分别登录
docker compose run --rm login -auth /app/auths/workbuddy-2.json
```

终端会打印二维码与浏览器直达链接。扫码成功后凭据自动保存到 `./data/auths/workbuddy*.json`。

> **最佳实践**：优先在浏览器打开链接，在 **CodeBuddy 控制台（网页端）** 完成登录。
> 直接扫码的账号渠道可能受限（`azp=invite`），权限评级较低。

### 2. 启动网关

```bash
docker compose up -d
```

### 3. 验证

```bash
curl http://127.0.0.1:8317/health      # {"status":"healthy",...}
curl http://127.0.0.1:8317/v1/models   # 模型列表
docker compose logs -f gateway         # 实时日志
```

服务地址：`http://127.0.0.1:8317/v1`

---

## 二、目录结构

容器把 `/app` 作为**唯一持久化挂载点**（compose 中 `./data:/app`）：

```
./data/
├── auths/
│   └── workbuddy*.json      # 凭据（账号池），login 写入 / 手动放入
├── workbuddy-status.json    # serve 每 3 秒写入的实时快照（monitor 读取）
└── logs/
    └── gateway-YYYY-MM-DD.log
```

`workbuddy-status.json` 路径在程序内硬编码为**相对当前工作目录**，因此 `serve`、`status`、`monitor` 三者必须共享同一工作目录 `/app` —— 挂载整个 `/app`（而非仅子目录）可天然满足这一点，避免 monitor 读不到状态文件。

---

## 三、登录方式选择

登录需要**交互式 TTY**。三种可行姿势：

### 方式 A：直接 run（最简单，交互式终端）

```bash
docker compose run --rm login
```

### 方式 B：前台运行，避免多网络创建

先 `docker compose up -d gateway`，再登录；凭据会被**热加载**自动纳入池，无需重启。

### 方式 C：服务器无交互终端（SSH 自动化 / CI）

二维码是终端 ASCII 输出，无法在无 TTY 环境扫码。改用**链接登录**：

```bash
# 后台跑登录，把输出重定向到文件
docker compose run --rm login > /tmp/login.log 2>&1 &

# 从日志里取出浏览器链接，在本地浏览器打开并完成登录
grep -o 'https://copilot.tencent.com/login[^ ]*' /tmp/login.log
```

登录成功后 `data/auths/` 会出现凭据文件。

---

## 四、多账号池

把多个凭据文件放进 `./data/auths/`，网关按 **round-robin 轮询**分发请求：

```bash
docker compose run --rm login -auth /app/auths/workbuddy-1.json
docker compose run --rm login -auth /app/auths/workbuddy-2.json
# 或直接往 ./data/auths/ 里拷备好的凭据文件
docker compose up -d
```

**凭据热加载**：`serve` 每 5 秒扫描一次凭据目录（`-reload-interval` 可调）。
新增 / 更新 / 删除凭据文件**均无需重启服务**，日志会打印：

```
[Reload] 发现新账号凭据 workbuddy2.json（国际站），已自动加入账号池
```

国内站与国际站账号可**混挂**在同一池中，凭据文件内 `edition` 字段决定路由到的上游。

---

## 五、运维命令

所有辅助命令通过 `cli` 服务执行（与 gateway 共享 `./data` 卷）：

```bash
docker compose run --rm cli status     # 账号池状态：可用/冷却/额度/Token 有效期
docker compose run --rm cli refresh    # 手动立即刷新所有访问令牌
docker compose run --rm cli monitor    # 前台实时监控（Ctrl+C 退出）
docker compose run --rm cli version    # 版本
```

`monitor` 也可附加日志：

```bash
docker compose run --rm cli monitor -journal workbuddy-gateway
docker compose run --rm cli monitor -lines 8
```

---

## 六、配置项

复制模板后按需修改：

```bash
cp .env.example .env
```

| 变量 | 默认 | 说明 |
|---|---|---|
| `GATEWAY_PORT` | `8317` | 监听端口（宿主与容器一致） |
| `GATEWAY_BIND` | `127.0.0.1` | 宿主绑定地址。**仅本机**默认；改 `0.0.0.0` 开放局域网，此时务必设 `GATEWAY_API_KEY` |
| `GATEWAY_API_KEY` | 空 | 网关访问密钥（Bearer）。非空即启用鉴权 |
| `UPSTREAM_PROXY` | 空 | 上游出口代理，如 `http://172.17.0.1:7890` |
| `MODELS_REFRESH` | `60` | 官方模型目录刷新间隔（分钟），`0` 关闭 |
| `TZ` | `Asia/Shanghai` | 时区（国内站每日签到按 UTC+8 09:00） |
| `PUID` / `PGID` | `1000` | 容器内运行身份，须与 `./data` 属主一致 |
| `GATEWAY_EXTRA_ARGS` | 空 | 逃生通道：任意额外 CLI 参数，如 `-verbose` |

### 启用客户端鉴权

```bash
# .env
GATEWAY_API_KEY=sk-your-strong-key
GATEWAY_BIND=0.0.0.0
```

```bash
docker compose up -d

curl -H "Authorization: Bearer sk-your-strong-key" \
     http://127.0.0.1:8317/v1/models     # 200
curl http://127.0.0.1:8317/v1/models      # 401
```

`/health`、`/ping`、`/` 三个端点**免鉴权**，便于探活与反向代理健康检查。

---

## 七、客户端接入

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8317/v1",
    api_key="none",          # 未启用 GATEWAY_API_KEY 时随意填
)
resp = client.chat.completions.create(
    model="hy4-preview",     # 模型完全透传，无白名单
    messages=[{"role": "user", "content": "你好"}],
)
print(resp.choices[0].message.content)
```

若网关部署在**另一台服务器**上，把 `base_url` 换成该服务器的 `http://<ip>:8317/v1`，
并确保 `.env` 中 `GATEWAY_BIND=0.0.0.0` 且已设置 `GATEWAY_API_KEY`。

---

## 八、构建与升级

```bash
# 重新构建（改代码后）
docker compose build

# 拉取上游最新代码后重建
git pull && docker compose build && docker compose up -d

# 完全清理（凭据保留在 ./data）
docker compose down
docker image rm workbuddy-gateway:latest
```

### 构建参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `GO_VERSION` | `1.26` | Go 工具链版本 |
| `GOPROXY` | `https://goproxy.cn,direct` | 模块代理。**国内必须用镜像**，否则 `proxy.golang.org` 超时导致构建失败 |
| `PUID` / `PGID` | `1000` | 运行用户 uid/gid |

```bash
docker compose build --build-arg GO_VERSION=1.26 --build-arg GOPROXY=https://goproxy.cn,direct
```

---

## 九、排障

### 构建时 `go mod download` 超时

```
dial tcp 142.250.73.81:443: i/o timeout
```

`proxy.golang.org` 在国内不可达。重建时指定镜像代理：

```bash
docker compose build --build-arg GOPROXY=https://goproxy.cn,direct
```

### 构建时 `apk add` 报 temporary error / no such package

```
WARNING: fetching https://dl-cdn.alpinelinux.org/alpine/v3.20/community: temporary error (try again later)
ERROR: unable to select packages:
  ca-certificates (no such package)
```

`dl-cdn.alpinelinux.org` 在国内常不可达。改用国内 apk 源：

```bash
docker compose build --build-arg ALPINE_MIRROR=mirrors.cloud.tencent.com
```

实测（腾讯云主机）：`mirrors.cloud.tencent.com` 稳定可用；
`mirrors.aliyun.com` 会出现 apk temporary error（但宿主机 curl 却是 200，**别被误导**）；
`tuna` / `ustc` 返回 403。

### 构建时域名解析失败（`bad address`）——最隐蔽

现象：宿主机 `curl` 域名正常、`docker run` 容器内也正常，
**唯独 `docker build` 的 RUN 步骤报解析失败**。

**先诊断 DNS，再怀疑镜像源**，避免白折腾：

```bash
docker build --network=host -t nettest -f- . <<'EOF'
FROM alpine:3.20
RUN cat /etc/resolv.conf
EOF
```

若输出形如 `nameserver fe80::5%enp2s0`（只有 IPv6 链路本地 DNS），
说明 BuildKit 构建容器没拿到可用 DNS。解绑办法是在 compose 的 build 段加：

```yaml
    build:
      context: .
      network: host      # 继承宿主机 DNS
```

或命令行 `docker build --network=host .`。

> 该配置**因主机而异**：有的主机 buildkit DNS 正常（加了反而会用宿主 DNS 出问题），
> 故 compose 里默认注释掉。按需启用。

### 无法本地构建时的替代方案：搬运镜像

若目标主机网络受限导致构建始终失败，可在另一台能构建的机器上构建后搬运：

```bash
# 在能构建的机器上
docker save workbuddy-gateway:latest | gzip -1 > wb.tar.gz

# 传到目标机
scp wb.tar.gz user@target:/tmp/
ssh user@target 'gunzip -c /tmp/wb.tar.gz | docker load'

# 跳过构建直接启动
docker compose up -d --no-build
```

### 容器内 `permission denied` 写文件失败

现象：日志出现 `open wb-models-cache.json.tmp: permission denied`，或 `login` 无法保存凭据。

原因：宿主机 `./data` 目录属主与容器内运行身份不一致。

```bash
# 查看宿主机目录属主
ls -lan data/

# 方案 1（推荐）：让 .env 中的 PUID/PGID 与之对齐
# 方案 2：直接修正宿主机目录属主
chown -R 1000:1000 data/
```

> 容器启动时 entrypoint 会**自动修正挂载点属主**（以 root 启动 → chown → `su-exec` 降权），
> 因此多数情况下无需手工处理。

### `docker compose run` 看不到二维码

`run` 需要 TTY。若在无 TTY 环境（CI、部分 SSH 非交互会话），改用第三节的「方式 C」链接登录。

### monitor 提示「未找到状态文件」

说明 `./data` 卷未共享，或 gateway 未运行。确认 `docker compose ps` 中 gateway 为 `Up`，
且 `cli` 与 `gateway` 挂载的是同一个 `./data:/app`。

### 端口被占用

修改 `.env` 的 `GATEWAY_PORT` 即可，宿主与容器端口会同步变化。

### 健康检查一直 `starting`

```bash
docker inspect workbuddy-gateway --format '{{json .State.Health}}' | python3 -m json.tool
```

容器内缺 `wget` 的情况不会发生（镜像已内置 busybox wget）；
若持续 unhealthy，先看 `docker compose logs gateway` 是否有启动错误。

---

## 十、安全提示

- `./data/auths/workbuddy*.json` 含真实 Access/Refresh Token，**严禁提交到 Git**。
  仓库 `.gitignore` 与 `.dockerignore` 已排除 `workbuddy*.json`、`data/`、`.env`。
- 默认只监听 `127.0.0.1`。对外开放前务必设置 `GATEWAY_API_KEY`，或置于 nginx 等反代之后。
- 容器默认**非 root 运行**（uid 1000，经 `su-exec` 降权）；仅 entrypoint 的权限修正阶段短暂使用 root。
- 不再使用的账号：删除对应凭据文件，并到 CodeBuddy 控制台撤销应用授权。
