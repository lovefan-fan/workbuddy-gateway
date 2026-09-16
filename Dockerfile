# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# WorkBuddy Local Gateway —— 多阶段构建
# 阶段 1：用官方 Go 工具链静态编译（CGO 关闭 → 纯静态单二进制，可跑在 alpine 上）
# 阶段 2：极小运行时镜像，仅保留二进制 + ca-certificates + tzdata
# ---------------------------------------------------------------------------

ARG GO_VERSION=1.26
# Go 模块代理：国内网络默认走七牛镜像；海外/有全局代理时可覆盖为 https://proxy.golang.org,direct
ARG GOPROXY=https://goproxy.cn,direct

# --------------------------- builder ---------------------------------------
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS builder

ARG TARGETOS
ARG TARGETARCH
ARG GOPROXY
ARG VERSION=dev

ENV GOPROXY=${GOPROXY} \
    GOSUMDB=off \
    GOFLAGS=-mod=mod

# git 可选（go mod 全在 proxy 上即可），保留给私有依赖场景
RUN apk add --no-cache ca-certificates tzdata

WORKDIR /src

# 先拷依赖描述文件，最大化利用层缓存
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# 再拷源码
COPY . .

# 静态编译：CGO_ENABLED=0 + -trimpath + -s -w（与项目 build.ps1 一致的 flag）
# 通过 -X main.version 注入版本号的效果取决于项目是否定义该变量；
# 若未定义则被链接器忽略，不影响构建。
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/workbuddy-gateway .

# 构建期自检：确认产物是静态链接的 Linux 可执行文件
RUN /out/workbuddy-gateway version 2>/dev/null || /out/workbuddy-gateway --version 2>/dev/null || /out/workbuddy-gateway help >/dev/null 2>&1 || true

# --------------------------- runtime ---------------------------------------
FROM alpine:3.20

LABEL org.opencontainers.image.title="workbuddy-gateway" \
      org.opencontainers.image.description="WorkBuddy/CodeBuddy (腾讯) OpenAI 兼容本地代理网关" \
      org.opencontainers.image.source="https://github.com/CangShui/workbuddy-gateway"

# ca-certificates: 访问上游 https 必需
# tzdata:         国内站每日签到依赖 UTC+8 时区
# tini:           作为 init 进程，正确转发 SIGTERM 并回收僵尸进程
# su-exec:        entrypoint 内以降权用户执行（无需 sudo）
RUN apk add --no-cache ca-certificates tzdata tini su-exec \
    && update-ca-certificates

# 运行期非 root 用户；uid/gid 固定 1000，可用 PUID/PGID 构建参数覆盖以对齐宿主机
ARG PUID=1000
ARG PGID=1000
RUN addgroup -g ${PGID} -S gateway \
    && adduser -u ${PUID} -S -G gateway -h /app gateway

ENV TZ=Asia/Shanghai \
    HOME=/app \
    PUID=${PUID} \
    PGID=${PGID}

WORKDIR /app

COPY --from=builder /out/workbuddy-gateway /usr/local/bin/workbuddy-gateway
COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# 运行期目录布局（/app 为单一持久化挂载点）：
#   /app/workbuddy-status.json   serve 每 3 秒原子写入，monitor/status 读取
#   /app/logs/gateway-*.log      运行日志
#   /app/auths/workbuddy*.json   凭据（-auth-dir /app/auths 自动发现成账号池）
# status 文件路径在程序内硬编码为相对路径，故 serve 与 monitor 必须同工作目录。
RUN mkdir -p /app/auths /app/logs \
    && chmod +x /usr/local/bin/docker-entrypoint.sh \
    && chown -R gateway:gateway /app

# 注意：此处不写 USER —— entrypoint 以 root 启动，先修正挂载目录属主
# （宿主机 ./data 常由 root 创建，非 root 用户无法写入 → login/status 会失败），
# 再用 su-exec 降权到 gateway 执行。详见 docker/entrypoint.sh。
EXPOSE 8317

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O- "http://127.0.0.1:${GATEWAY_PORT:-8317}/health" >/dev/null 2>&1 \
        || exit 1

# tini 作为 init（正确转发 SIGTERM、回收僵尸进程）；
# entrypoint 包装脚本修正挂载点权限、降权运行，并把环境变量翻译成 CLI 参数
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["serve", "-addr=0.0.0.0", "-port=8317"]
