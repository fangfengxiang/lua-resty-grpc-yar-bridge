#!/usr/bin/env bash
# scenario1_yar2grpc.sh — 场景1：PHP Yar client → OpenResty (reverse bridge) → Go gRPC server
#
# 启动 Go gRPC server + OpenResty reverse bridge，运行 PHP Yar client 验证。
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

C() { printf '\033[0;36m[e2e-s1/%s]\033[0m %s\n' "$PACKAGER" "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

# 确保退出时清理所有进程（无论 PASS/FAIL/异常退出）
cleanup() {
    C "cleaning up scenario 1..."
    [ -f "$RUN/go_s1_${PACKAGER}.pid" ] && kill "$(cat "$RUN/go_s1_${PACKAGER}.pid")" 2>/dev/null || true
    [ -f "$RUN/nginx_yar2grpc_${PACKAGER}.conf" ] && "$NGINX" -c "$RUN/nginx_yar2grpc_${PACKAGER}.conf" -s stop 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# ── 依赖检查 ──
[ -x "$NGINX" ] || F "OpenResty not found at $NGINX"
command -v php >/dev/null || F "php not found"
php -m 2>/dev/null | grep -qx "yar" || C "WARN: php-yar ext missing"
[ -f "$BIN/grpc_server" ] || F "grpc_server not built (run run_e2e.sh first)"

# ── 生成 nginx conf（替换占位符）──
C "preparing nginx config (packager=$PACKAGER)..."
sed -e "s|@RUN@|$RUN|g" -e "s|@PREFIX@|$ROOT|g" -e "s|@PACKAGER@|$PACKAGER|g" \
    -e "s|@PORT_YAR2GRPC@|$E2E_PORT_YAR2GRPC|g" -e "s|@PORT_GO_HTTP@|$E2E_PORT_GO_HTTP|g" \
    "$D/nginx/nginx_yar2grpc.conf" > "$RUN/nginx_yar2grpc_${PACKAGER}.conf"

# ── 启动 Go gRPC server (gRPC :50051, HTTP bridge :50052) ──
C "starting Go gRPC server (gRPC :50051, HTTP bridge :50052)..."
"$BIN/grpc_server" -addr 127.0.0.1:${E2E_PORT_GO_GRPC} -http-addr 127.0.0.1:${E2E_PORT_GO_HTTP} >"$LOG/go_s1_${PACKAGER}.log" 2>&1 &
echo $! > "$RUN/go_s1_${PACKAGER}.pid"
sleep 1

# ── 启动 OpenResty (reverse bridge, port 1985) ──
C "starting OpenResty (reverse bridge, port 1985)..."
"$NGINX" -c "$RUN/nginx_yar2grpc_${PACKAGER}.conf" -p "$ROOT" >>"$LOG/nginx_s1_${PACKAGER}.log" 2>&1 &
echo $! > "$RUN/nginx_s1_${PACKAGER}_ng.pid"
sleep 1

# ── 运行 PHP Yar client（yar.packager + zend.assertions=1 + assert.exception=1）──
# zend.assertions=1 确保 assert() 执行（PHP 8+ 默认可能禁用，导致值断言失效）
# assert.exception=1 让失败的 assert 抛 AssertionError 中断脚本（PHP 默认仅 Warning，
#   不中断 → 继续执行到 echo PASS → grep 误判 PASS）。Issue 1 防假 PASS 的关键。
C "running PHP Yar client (packager=$PACKAGER)..."
OUT="$LOG/s1_${PACKAGER}_result.log"
if php -d yar.packager="$PACKAGER" -d zend.assertions=1 -d assert.exception=1 \
    "$D/php/yar_client/client.php" 2>&1 | tee "$OUT"; then
    if grep -q "Scenario 1.*PASS" "$OUT"; then
        P "Scenario 1 ($PACKAGER): PASS"
    else
        F "Scenario 1 ($PACKAGER): FAIL (assertion markers not found in output)"
    fi
else
    F "Scenario 1 ($PACKAGER): FAIL (client exited non-zero)"
fi

# ── Issue 3: 错误路径覆盖（service 未注册 → 404）──
# 400（service_name 变量缺失）由 location 正则保证非空，正常请求路径不可达，
# 属 handle() 防御性兜底；此处覆盖可达的 404（service 未注册）。
C "checking 404 path (unregistered service)..."
ERR_FILE="$LOG/s1_${PACKAGER}_404_body.txt"
HTTP_CODE=$(curl -s -o "$ERR_FILE" -w "%{http_code}" -X POST http://127.0.0.1:${E2E_PORT_YAR2GRPC}/api/nonexistent.Service)
ERR_BODY="$(cat "$ERR_FILE")"
if [ "$HTTP_CODE" = "404" ] && echo "$ERR_BODY" | grep -q "service not registered: nonexistent.Service"; then
    P "404 path: PASS (unregistered service returns 404 + correct message)"
else
    F "404 path: FAIL (expected 404 + 'service not registered', got $HTTP_CODE: $ERR_BODY)"
fi

# ── Issue 4: 并发不读串验证（单 worker 协程隔离）──
# nginx conf worker_processes=1，所有请求在同 worker 协程切换，是验证
# ngx.var.service_name 请求级隔离的最佳场景。交叉并发：
#   - N 个 PHP yar client 打正常 service calculator.Calculator（应全 PASS）
#   - N 个 curl 打不存在的 service nonexistent.Service（应全 404）
# 若 ngx.var.service_name 跨请求串：PHP 会拿到 nonexistent → 404 中断 → 不输出 PASS；
# curl 会拿到 calculator → 进 YAR handle → 非 404。断言 PHP 全 PASS + curl 全 404 即证伪读串。
N_CONC="${N_CONC:-5}"
C "checking concurrency isolation (single-worker, cross-service, N=$N_CONC)..."
rm -f "$LOG"/s1_${PACKAGER}_conc_php_*.log "$LOG"/s1_${PACKAGER}_conc_curl_*.log
CONC_PIDS=""
for i in $(seq 1 "$N_CONC"); do
    php -d yar.packager="$PACKAGER" -d zend.assertions=1 -d assert.exception=1 \
        "$D/php/yar_client/client.php" >"$LOG/s1_${PACKAGER}_conc_php_$i.log" 2>&1 &
    CONC_PIDS="$CONC_PIDS $!"
done
for i in $(seq 1 "$N_CONC"); do
    curl -s -o /dev/null -w "%{http_code}\n" -X POST \
        http://127.0.0.1:${E2E_PORT_YAR2GRPC}/api/nonexistent.Service >"$LOG/s1_${PACKAGER}_conc_curl_$i.log" &
    CONC_PIDS="$CONC_PIDS $!"
done
# wait 指定 pid：只等 php/curl 子进程。无参 wait 会等待所有后台作业（含 grpc_server/nginx
# 这类长期运行的服务进程，它们不会自行退出）→ 死锁。这是 wait 无参数的陷阱。
wait $CONC_PIDS

PHP_FAIL=0; CURL_FAIL=0; CURL_BAD=""
for i in $(seq 1 "$N_CONC"); do
    grep -q "Scenario 1.*PASS" "$LOG/s1_${PACKAGER}_conc_php_$i.log" || PHP_FAIL=$((PHP_FAIL+1))
    CODE="$(cat "$LOG/s1_${PACKAGER}_conc_curl_$i.log")"
    [ "$CODE" = "404" ] || { CURL_FAIL=$((CURL_FAIL+1)); CURL_BAD="$CURL_BAD $CODE"; }
done
if [ "$PHP_FAIL" -eq 0 ] && [ "$CURL_FAIL" -eq 0 ]; then
    P "concurrency isolation: PASS ($N_CONC PHP + $N_CONC curl, no cross-contamination)"
else
    F "concurrency isolation: FAIL (php_fail=$PHP_FAIL curl_fail=$CURL_FAIL codes=[$CURL_BAD ] — possible ngx.var.service_name cross-contamination)"
fi

# 清理由 trap EXIT 自动处理
