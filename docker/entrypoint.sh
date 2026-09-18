#!/bin/sh
# ---------------------------------------------------------------------------
# 容器入口包装。三件事：
#   1) 修正挂载目录属主（宿主机 ./data 常归 root，非 root 用户写不进去
#      → login 无法保存凭据、status 快照/缓存写入失败）
#   2) 把 compose 环境变量翻译成 CLI 参数
#      （compose 的 command 列表不做变量展开，-api-key / -proxy 只能在此拼装）
#   3) 以降权用户执行（PUID/PGID，默认 1000）
#
# 环境变量：
#   PUID / PGID        运行身份（默认 1000:1000），须与宿主机挂载目录属主一致
#   RUN_AS_ROOT=1      跳过降权，以 root 运行（不推荐）
#   GATEWAY_API_KEY    非空时给 serve 追加 -api-key；probe 会自动携带同一密钥
#   UPSTREAM_PROXY     非空时给 serve 追加 -proxy（上游出口代理）
#   GATEWAY_PROBE_ADDR probe 访问的网关地址（容器内默认 gateway，即 compose 服务名）
#   GATEWAY_EXTRA_ARGS 额外 CLI 参数（空格分隔），原样追加到末尾
#
# 用法与原生 CLI 完全一致：
#   docker compose run --rm login -intl    →  login -intl
#   docker compose run --rm cli status     →  status -auth-dir /app/auths
#   docker compose run --rm cli probe      →  probe -addr gateway -port 8317 -api-key ***
# ---------------------------------------------------------------------------
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
APP_DIR=/app
AUTH_DIR="$APP_DIR/auths"

# ---------------------------------------------------------------------------
# 1) 权限修正 + 2) 参数拼装 + 3) 降权执行
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ] && [ "${RUN_AS_ROOT:-0}" != "1" ]; then
    # 只 chown 挂载点本身与运行期所需的两个子目录，避免在大目录上做全量遍历
    chown "${PUID}:${PGID}" "$APP_DIR" 2>/dev/null || true
    mkdir -p "$AUTH_DIR" "$APP_DIR/logs"
    chown -R "${PUID}:${PGID}" "$AUTH_DIR" "$APP_DIR/logs" 2>/dev/null || true

    exec su-exec "${PUID}:${PGID}" "$0" "$@"
fi

if [ -z "$1" ]; then
    echo "用法: <command> [args...]" >&2
    echo "命令: serve | login | status | refresh | monitor | probe | reset | version | help" >&2
    exit 1
fi

CMD="$1"
shift

# ---------------------------------------------------------------------------
# 参数补全。各子命令语义不同，逐个处理（不要想当然复用）：
#
#   login                      -auth <文件>    保存凭据到该文件
#   serve/status/refresh/reset -auth-dir <目录> 扫描目录下所有 workbuddy*.json
#   probe                      无凭据参数可用；它通过 HTTP 调用运行中的 serve
#                              （POST /admin/probe），需 -addr/-port/-api-key
#   monitor                    读工作目录的 workbuddy-status.json，无需参数
# ---------------------------------------------------------------------------
case "$CMD" in
    login)
        # 未显式指定时自动分配不冲突的文件名，避免第二次登录覆盖第一个账号
        case " $* " in
            *" -auth "*|*" -auth-dir "*) : ;;
            *)
                target="$AUTH_DIR/workbuddy.json"
                if [ -f "$target" ]; then
                    n=2
                    while [ -f "$AUTH_DIR/workbuddy$n.json" ]; do
                        n=$((n + 1))
                    done
                    target="$AUTH_DIR/workbuddy$n.json"
                    echo "[entrypoint] auths/workbuddy.json 已存在，改用 $(basename "$target")（多账号模式）"
                fi
                set -- "$@" -auth "$target"
                ;;
        esac
        ;;

    serve|status|refresh|reset|run|start)
        case " $* " in
            *" -auth "*|*" -auth-dir "*) : ;;
            *) set -- "$@" -auth-dir "$AUTH_DIR" ;;
        esac
        ;;

    probe)
        # 通过 HTTP 访问运行中的 serve。容器场景下 serve 在 gateway 服务里，
        # 由 GATEWAY_PROBE_ADDR 指定（compose 默认 gateway:8317）。
        # -auth 用于筛选探测哪个账号，属可选，故不自动追加。
        case " $* " in
            *" -addr "*) : ;;
            *) set -- "$@" -addr "${GATEWAY_PROBE_ADDR:-gateway}" ;;
        esac
        case " $* " in
            *" -port "*) : ;;
            *) set -- "$@" -port "${GATEWAY_PORT:-8317}" ;;
        esac
        ;;
esac

# 可选：网关访问鉴权
#   serve 用 -api-key 设定密钥；probe 用同一个 -api-key 自动携带
if [ -n "$GATEWAY_API_KEY" ]; then
    case "$CMD" in
        serve|probe) set -- "$@" -api-key "$GATEWAY_API_KEY" ;;
    esac
fi

# 可选：上游出口代理
if [ -n "$UPSTREAM_PROXY" ]; then
    case "$CMD" in
        serve) set -- "$@" -proxy "$UPSTREAM_PROXY" ;;
    esac
fi

# 额外参数
if [ -n "$GATEWAY_EXTRA_ARGS" ]; then
    # shellcheck disable=SC2086
    set -- "$@" $GATEWAY_EXTRA_ARGS
fi

exec workbuddy-gateway "$CMD" "$@"
