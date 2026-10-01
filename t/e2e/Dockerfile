# Dockerfile — e2e 测试环境镜像（参考 lua-yar Docker CI 模式）
#
# 镜像只装依赖（OpenResty + PHP + Go + protoc + Lua 库），项目源码通过
# docker run -v "$(pwd):/app" 挂载，镜像可跨 CI 运行缓存，源码改动无需重建。
#
# 构建：docker build -t yar-grpc-bridge-e2e -f t/e2e/Dockerfile t/e2e/
# 运行：docker run --rm -v "$(pwd):/app" -w /app yar-grpc-bridge-e2e bash t/e2e/run_e2e.sh
# 本地：bash docker-test.sh

FROM openresty/openresty:jammy

# 避免 tzdata 等包的交互式提问导致构建卡住
ENV DEBIAN_FRONTEND=noninteractive

# ── 系统依赖：PHP + 编译工具 + protoc ──
RUN apt-get update && apt-get install -y --no-install-recommends \
        tzdata \
        php8.1-cli \
        php8.1-dev \
        php8.1-curl \
        php8.1-mbstring \
        php-pear \
        libcurl4-openssl-dev \
        libxml2-dev \
        protobuf-compiler \
        build-essential \
        git \
        rsync \
        ca-certificates \
        curl \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# ARM64 上 libcurl 头文件在 /usr/include/aarch64-linux-gnu/curl/，
# yar 的 configure 只检查 /usr/include/curl/，创建符号链接解决
RUN MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)" \
    && if [ -d "/usr/include/${MULTIARCH}/curl" ] && [ ! -d /usr/include/curl ]; then \
        ln -s "/usr/include/${MULTIARCH}/curl" /usr/include/curl; \
    fi

# ── PHP yar + msgpack 扩展 ──
# 安装顺序和编译选项都至关重要：
# 1. 先装 msgpack：使 msgpack 头文件安装到 PHP include 目录 (ext/msgpack/)
# 2. yar 必须手动编译并传 --enable-msgpack：
#    config.m4 中 PHP_ARG_ENABLE(msgpack, ..., no, no) 默认禁用，
#    pecl install yar -- --enable-msgpack 语法无效（PECL 误将 --enable-msgpack 当包名），
#    导致 configure --enable-msgpack=no，msgpack packager 未编译进 yar.so。
#    运行时 yar.packager=msgpack 静默回退到 PHP serialize 格式，
#    Lua msgpack 解码器收到 PHP serialize 字节（首字节 0x61='a'）误解读为正整数，
#    Response.unpack(数字) 崩溃：attempt to index local 't' (a number value)
# 3. zend.assertions=1：PHP 8+ 默认 php.ini 可能设 zend.assertions=-1（不执行 assert()），
#    必须显式开启，否则 scenario1 的值断言（assert($result === 42)）失效，
#    即使返回值错误也 exit 0 → 误报 PASS。scenario1 的 php 命令也双保险加 -d zend.assertions=1。
RUN pecl install msgpack \
    && cd /tmp && pecl download yar && tar xf yar-*.tgz && cd yar-*/ \
    && phpize && ./configure --enable-msgpack \
    && make -j"$(nproc)" && make install \
    && cd /tmp && rm -rf /tmp/yar-* \
    && echo "extension=msgpack.so" > "$(php-config --ini-dir)/20-msgpack.ini" \
    && echo "extension=yar.so"      > "$(php-config --ini-dir)/30-yar.ini" \
    && echo "zend.assertions=1"     > "$(php-config --ini-dir)/99-assertions.ini"

# ── Go 工具链（apt 版太旧，从官网安装最新稳定版）──
# 自动检测容器架构（x86_64 → amd64, aarch64 → arm64），适配 Apple Silicon 和 x86。
RUN ARCH="$(uname -m)" \
    && case "$ARCH" in \
        x86_64)  GOARCH="amd64" ;; \
        aarch64) GOARCH="arm64" ;; \
        *) echo "unsupported arch: $ARCH"; exit 1 ;; \
    esac \
    && GO_VER="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)" \
    && curl -fsSL "https://go.dev/dl/${GO_VER}.linux-${GOARCH}.tar.gz" \
       | tar -C /usr/local -xzf -
ENV PATH="${PATH}:/usr/local/go/bin:/root/go/bin"
ENV GOPATH=/root/go
ENV GOFLAGS=-mod=mod

# ── Go protoc 插件（gen.sh 生成 Go gRPC 代码依赖）──
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@latest \
    && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# ── Lua 依赖（单条 luarocks install 连带装 lua-yar + lua-protobuf）──
# lua-yar-grpc 的 rockspec 已声明 dependencies = {lua-yar, lua-protobuf}，
# luarocks 自动递归安装。lua-yar / lua-protobuf 版本由 rockspec 决定。
# 装到 OpenResty luajit 标准路径，e2e nginx 的 ;; 默认 LUA_PATH 可查找。
#
# 不锁版本号：lua-yar-grpc 是 yar-group 自家库，e2e 的目标是验证最新发布版
# 能与 bridge 正常互操作，而非复现某个历史版本。发版后无需回来改 Dockerfile。
# 真需复现某次构建时，用 git commit + Docker image tag 锁定整个镜像更可靠。
RUN /usr/local/openresty/luajit/bin/luarocks install lua-yar-grpc

# OpenResty 在容器内的标准路径
ENV OPENRESTY_PREFIX=/usr/local/openresty

# ── 打印已装依赖版本（build 日志可见，便于排查"版本漂移"问题）──
RUN echo "=== Installed dependency versions ===" \
    && echo "--- OpenResty ---" \
    && /usr/local/openresty/nginx/sbin/nginx -v 2>&1 \
    && echo "--- LuaRocks packages ---" \
    && /usr/local/openresty/luajit/bin/luarocks list \
    && echo "--- PHP extensions (yar/msgpack) ---" \
    && php -m | grep -iE '^(yar|msgpack)$' \
    && echo "--- PHP zend.assertions ---" \
    && php -r 'echo "zend.assertions=" . ini_get("zend.assertions") . "\n";' \
    && echo "--- Go ---" \
    && go version \
    && echo "--- protoc ---" \
    && protoc --version \
    && echo "--- protoc-gen-go ---" \
    && protoc-gen-go --version \
    && echo "=== versions OK ==="

# 项目源码通过 docker run -v 挂载到 /app，镜像不含源码（可缓存）
WORKDIR /app
