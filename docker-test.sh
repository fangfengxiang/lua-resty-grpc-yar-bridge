#!/usr/bin/env bash
# docker-test.sh — 构建 Docker 镜像并运行 e2e 测试
#
# 参考 lua-yar Docker CI 模式：镜像只装依赖，项目源码通过 -v 挂载。
# 镜像可缓存，源码改动无需重建。
#
# 用法：
#   bash docker-test.sh              构建（带缓存）+ 运行
#   bash docker-test.sh --no-cache   无缓存构建 + 运行
#   bash docker-test.sh --build-only  仅构建镜像不运行
#   bash docker-test.sh --run-only    仅运行已有镜像
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE_TAG="yar-grpc-bridge-e2e:latest"

C() { printf '\033[0;36m[docker-test]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

# ── 解析参数 ──
NO_CACHE=""
BUILD_ONLY=""
RUN_ONLY=""
for arg in "$@"; do
    case "$arg" in
        --no-cache)   NO_CACHE="--no-cache" ;;
        --build-only) BUILD_ONLY="1" ;;
        --run-only)   RUN_ONLY="1" ;;
        *) F "unknown argument: $arg" ;;
    esac
done

# ── 检查 Docker ──
command -v docker >/dev/null || F "docker not found"
docker info >/dev/null 2>&1 || F "docker daemon not running"

# ── 构建（镜像只装依赖，context = t/e2e，不含项目源码）──
if [[ -z "$RUN_ONLY" ]]; then
    C "building Docker image ($IMAGE_TAG)..."
    docker build $NO_CACHE \
        -f "$ROOT/t/e2e/Dockerfile" \
        -t "$IMAGE_TAG" \
        "$ROOT/t/e2e"
    C "image built: $IMAGE_TAG"
fi

# ── 运行（项目源码 -v 挂载到 /app）──
if [[ -z "$BUILD_ONLY" ]]; then
    C "running e2e tests in container..."
    echo ""
    # --rm：退出后自动清理容器
    # -v：挂载项目源码到 /app（镜像无源码，靠挂载提供）
    # exit code 透传：docker run 退出码 = run_e2e.sh 退出码
    docker run --rm -v "$ROOT:/app" -w /app "$IMAGE_TAG" bash t/e2e/run_e2e.sh
    EXIT_CODE=$?
    echo ""
    if [[ $EXIT_CODE -eq 0 ]]; then
        C "e2e tests PASSED (exit code: $EXIT_CODE)"
    else
        F "e2e tests FAILED (exit code: $EXIT_CODE)"
    fi
fi
