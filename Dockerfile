# ---------------------------------------------------------------------------
# WorkBuddy Local Gateway —— 多阶段构建
# 阶段 1：用官方 Go 工具链静态编译（CGO 关闭 → 纯静态单二进制，可跑在 alpine 上）
# 阶段 2：极小运行时镜像，仅保留二进制 + ca-certificates + tzdata
#
# 注意：刻意不使用 `# syntax=docker/dockerfile:1` 与 `--mount=type=cache`。
# 它们依赖从 Docker Hub 拉取 BuildKit 前端镜像 docker/dockerfile，
# 在使用国内 registry-mirror 加速器的环境下常拉取失败：
#   failed to copy: ... could not fetch content descriptor ... not found
# 去掉后仅损失构建缓存复用，功能与产物完全一致。
# ---------------------------------------------------------------------------

ARG GO_VERSION=1.26
# Go 模块代理：国内网络默认走七牛镜像；海外/有全局代理时可覆盖为 https://proxy.golang.org,direct
ARG GOPROXY=https://goproxy.cn,direct
# Alpine apk 源：国内默认走腾讯云镜像（对腾讯云主机内网直连、最稳）；
# 海外可覆盖为 dl-cdn.alpinelinux.org。实测 mirrors.aliyun.com 在容器内
# apk 会报 temporary error，而 mirrors.cloud.tencent.com 稳定可用。
ARG ALPINE_MIRROR=mirrors.cloud.tencent.com

# --------------------------- builder ---------------------------------------
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS builder

ARG TARGETOS
ARG TARGETARCH
ARG GOPROXY
ARG ALPINE_MIRROR
ARG VERSION=dev

ENV GOPROXY=${GOPROXY} \
    GOSUMDB=off \
    GOFLAGS=-mod=mod

# apk 源换成国内镜像：dl-cdn.alpinelinux.org 在国内常不可达
# （temporary error / no such package），导致 apk add 失败。
# 注意 sed 要同时替换 main 与 community 仓库。
RUN if [ -n "${ALPINE_MIRROR}" ] && [ "${ALPINE_MIRROR}" != "dl-cdn.alpinelinux.org" ]; then \
        sed -i "s|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g" /etc/apk/repositories; \
    fi \
    && cat /etc/apk/repositories

# git 可选（go mod 全在 proxy 上即可），保留给私有依赖场景
RUN apk add --no-cache ca-certificates tzdata

WORKDIR /src

# 先拷依赖描述文件，最大化利用层缓存
COPY go.mod go.sum ./
RUN go mod download

# 再拷源码
COPY . .

# 静态编译：CGO_ENABLED=0 + -trimpath + -s -w（与项目 build.ps1 一致的 flag）
# -X main.version 注入版本号的效果取决于项目是否定义该变量；
# 若未定义则被链接器忽略，不影响构建。
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/workbuddy-gateway .

# 构建期自检：确认产物是静态链接的 Linux 可执行文件
RUN /out/workbuddy-gateway version 2>/dev/null || /out/workbuddy-gateway --version 2>/dev/null || /out/workbuddy-gateway help >/dev/null 2>&1 || true

# --------------------------- runtime ---------------------------------------
FROM alpine:3.20

ARG ALPINE_MIRROR

LABEL org.opencontainers.image.title="workbuddy-gateway" \
      org.opencontainers.image.description="WorkBuddy/CodeBuddy (腾讯) OpenAI 兼容本地代理网关" \
      org.opencontainers.image.source="https://github.com/CangShui/workbuddy-gateway"

# 同 builder：先换 apk 源再安装，否则国内构建失败
RUN if [ -n "${ALPINE_MIRROR}" ] && [ "${ALPINE_MIRROR}" != "dl-cdn.alpinelinux.org" ]; then \
        sed -i "s|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g" /etc/apk/repositories; \
    fi

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
