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
#   GATEWAY_API_KEY    非空时给 serve 追加 -api-key（客户端 Bearer 鉴权）
#   UPSTREAM_PROXY     非空时给 serve 追加 -proxy（上游出口代理）
#   GATEWAY_EXTRA_ARGS 额外 CLI 参数（空格分隔），原样追加到末尾
#
# 用法与原生 CLI 完全一致：
#   docker compose run --rm login -intl    →  login -intl
#   docker compose run --rm cli status     →  status
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
    echo "命令: serve | login | status | refresh | monitor | version | help" >&2
    exit 1
fi

CMD="$1"
shift

# 凭据路径缺省值。注意 login 与其他子命令的参数语义不同：
#   - serve/status/refresh 用 -auth-dir <目录>（自动发现目录下所有 workbuddy*.json）
#   - login 用 -auth <文件路径>（参数名不同！）
# 若给 login 追加 -auth-dir 是无效的，凭据会落到工作目录根的 workbuddy.json，
# 而 serve 扫描的是 auths/ 目录 → 出现「登录成功但账号池为 0」。
case "$CMD" in
    login)
        case " $* " in
            *" -auth "*|*" -auth-dir "*) : ;;   # 已显式指定，不干预
            *) set -- "$@" -auth "$AUTH_DIR/workbuddy.json" ;;
        esac
        ;;
    serve|status|refresh)
        case " $* " in
            *" -auth "*|*" -auth-dir "*) : ;;
            *) set -- "$@" -auth-dir "$AUTH_DIR" ;;
        esac
        ;;
esac

# 可选：网关访问鉴权
if [ -n "$GATEWAY_API_KEY" ]; then
    case "$CMD" in
        serve) set -- "$@" -api-key "$GATEWAY_API_KEY" ;;
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
