#!/usr/bin/env bash
# run_e2e.sh — e2e 总入口
#
# 职责：依赖检查（严格，缺失即 FAIL）+ proto 生成 + Go 编译 → 依次启动两个场景脚本
#
# Scenario 1: PHP Yar → OpenResty (yar2grpc) → Go gRPC   (scenario1_yar2grpc.sh)
# Scenario 2: Go gRPC → OpenResty (forward_bridge) → PHP Yar   (scenario2_grpc2yar.sh)
#
# 所有运行态产物（编译产物、日志、pid、nginx temp）在 .run/ 目录下。
set -euo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
OR="${OPENRESTY_PREFIX:-/usr/local/openresty}"
NGINX="$OR/nginx/sbin/nginx"
RUN="$D/.run"
LOG="$RUN/logs"
BIN="$RUN/bin"
mkdir -p "$RUN" "$LOG" "$BIN"

# e2e 端口集中定义（改一处即同步 listen/proxy_pass/url/client，避免散落不一致）
# 子脚本 scenario1/2 继承这些变量；nginx conf 占位符 @PORT_*@ 由 sed 替换为对应值
export E2E_PORT_PHP="${E2E_PORT_PHP:-8888}"            # PHP Yar Server
export E2E_PORT_GRPC2YAR="${E2E_PORT_GRPC2YAR:-1984}"  # OpenResty forward bridge (HTTP/2)
export E2E_PORT_YAR2GRPC="${E2E_PORT_YAR2GRPC:-1985}"  # OpenResty reverse bridge (HTTP/1.1)
export E2E_PORT_GO_GRPC="${E2E_PORT_GO_GRPC:-50051}"   # Go gRPC server
export E2E_PORT_GO_HTTP="${E2E_PORT_GO_HTTP:-50052}"    # Go HTTP-to-gRPC bridge

C() { printf '\033[0;36m[e2e]\033[0m %s\n' "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

# ── 依赖检查（严格模式：缺失即 FAIL，不跳过任何场景）──
# e2e 覆盖 json + msgpack 两种打包器，PHP 必须有 yar + msgpack 扩展。
# 本地无 msgpack 扩展时，应改用 docker-test.sh（镜像含全部依赖）。
C "checking deps (strict)..."
[ -x "$NGINX" ] || F "OpenResty not found at $NGINX"
command -v php >/dev/null || F "php not found"
command -v go >/dev/null || F "go not found"
command -v protoc >/dev/null || F "protoc not found"
php -m 2>/dev/null | grep -qx "yar" \
    || F "php-yar ext missing (install: pecl install yar -- --enable-msgpack)"
php -m 2>/dev/null | grep -qx "msgpack" \
    || F "php-msgpack ext missing (required for msgpack scenario; use docker-test.sh if local PHP lacks it)"

# ── 依赖版本（运行时确认，便于排查环境差异）──
C "dependency versions:"
"$NGINX" -v 2>&1 | head -1
php -v 2>/dev/null | head -1
go version
protoc --version

# ── proto 生成 ──
C "generating proto..."
bash "$D/proto/gen.sh"

# ── 编译 Go ──
C "building Go binaries -> $BIN/ ..."
cd "$D/go"
# -buildvcs=false: Go 1.18+ 默认 VCS stamping，Docker -v 挂载宿主机 .git 时
# owner 不符触发 "dubious ownership"（exit 128）→ go build 失败
go build -buildvcs=false -o "$BIN/grpc_server" ./grpc_server || F "server build failed"
go build -buildvcs=false -o "$BIN/grpc_client" ./grpc_client || F "client build failed"

# ── 循环两种 YAR 打包器（json / msgpack）──
# PHP yar 扩展和 lua-yar 支持 json / msgpack 两种打包器，
# e2e 分别覆盖两种场景确保协议兼容。两者都必须通过，不跳过。
for PACKAGER in json msgpack; do
    export YAR_PACKAGER="$PACKAGER"

    # 场景2：Go gRPC → OpenResty → PHP Yar
    echo ""
    C "=== Scenario 2: Go gRPC → OpenResty → PHP Yar ($PACKAGER) ==="
    bash "$D/scenario2_grpc2yar.sh"

    # 场景1：PHP Yar → OpenResty → Go gRPC
    echo ""
    C "=== Scenario 1: PHP Yar → OpenResty → Go gRPC ($PACKAGER) ==="
    bash "$D/scenario1_yar2grpc.sh"
done

echo ""
P "All e2e tests completed."
echo "  logs:      $LOG/"
echo "  binaries:  $BIN/"
