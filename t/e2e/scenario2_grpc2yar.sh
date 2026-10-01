#!/usr/bin/env bash
# scenario2_grpc2yar.sh — 场景2：Go gRPC client → OpenResty (forward bridge) → PHP Yar server
#
# 启动 PHP Yar server + OpenResty forward bridge，运行 Go gRPC client 验证。
# 通过 YAR_PACKAGER 环境变量控制打包器（json 或 msgpack），默认 json。
# 所有日志、pid、编译产物在 .run/ 目录下。
set -euo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
OR="${OPENRESTY_PREFIX:-/usr/local/openresty}"
NGINX="$OR/nginx/sbin/nginx"
RUN="$D/.run"
LOG="$RUN/logs"
BIN="$RUN/bin"
PACKAGER="${YAR_PACKAGER:-json}"
mkdir -p "$RUN" "$LOG" "$BIN"

C() { printf '\033[0;36m[e2e-s2/%s]\033[0m %s\n' "$PACKAGER" "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

# 确保退出时清理所有进程（无论 PASS/FAIL/异常退出）
cleanup() {
    C "cleaning up scenario 2..."
    [ -f "$RUN/php_s2_${PACKAGER}.pid" ] && kill "$(cat "$RUN/php_s2_${PACKAGER}.pid")" 2>/dev/null || true
    [ -f "$RUN/nginx_grpc2yar_${PACKAGER}.conf" ] && "$NGINX" -c "$RUN/nginx_grpc2yar_${PACKAGER}.conf" -s stop 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# ── 依赖检查 ──
[ -x "$NGINX" ] || F "OpenResty not found at $NGINX"
command -v php >/dev/null || F "php not found"
[ -f "$BIN/grpc_client" ] || F "grpc_client not built (run run_e2e.sh first)"

# ── 生成 nginx conf（替换占位符）──
C "preparing nginx config (packager=$PACKAGER)..."
sed -e "s|@RUN@|$RUN|g" -e "s|@PREFIX@|$ROOT|g" -e "s|@PACKAGER@|$PACKAGER|g" \
    -e "s|@PORT_GRPC2YAR@|$E2E_PORT_GRPC2YAR|g" -e "s|@PORT_PHP@|$E2E_PORT_PHP|g" \
    "$D/nginx/nginx_grpc2yar.conf" > "$RUN/nginx_grpc2yar_${PACKAGER}.conf"

# ── 启动 PHP Yar server（设置 yar.packager 匹配 lua-yar 打包器）──
C "starting PHP Yar server (port 8888, packager=$PACKAGER)..."
php -d yar.packager="$PACKAGER" -S 127.0.0.1:${E2E_PORT_PHP} -t "$D/php/yar_server" >"$LOG/php_s2_${PACKAGER}.log" 2>&1 &
echo $! > "$RUN/php_s2_${PACKAGER}.pid"
sleep 1

# ── 启动 OpenResty (forward bridge, port 1984) ──
C "starting OpenResty (forward bridge, port 1984)..."
"$NGINX" -c "$RUN/nginx_grpc2yar_${PACKAGER}.conf" -p "$ROOT" >>"$LOG/nginx_s2_${PACKAGER}.log" 2>&1 &
echo $! > "$RUN/nginx_s2_${PACKAGER}_ng.pid"
sleep 1

# ── 运行 Go gRPC client ──
# 断言双层：① client exit code（内部 log.Fatalf on value mismatch）
#           ② grep 输出确认 Add/Subtract 均打印 PASS 标记
C "running Go gRPC client..."
OUT="$LOG/s2_${PACKAGER}_result.log"
if "$BIN/grpc_client" -addr 127.0.0.1:${E2E_PORT_GRPC2YAR} 2>&1 | tee "$OUT"; then
    if grep -q "Add: PASS" "$OUT" && grep -q "Subtract: PASS" "$OUT"; then
        P "Scenario 2 ($PACKAGER): PASS"
    else
        F "Scenario 2 ($PACKAGER): FAIL (assertion markers not found in output)"
    fi
else
    F "Scenario 2 ($PACKAGER): FAIL (client exited non-zero)"
fi

# 清理由 trap EXIT 自动处理
