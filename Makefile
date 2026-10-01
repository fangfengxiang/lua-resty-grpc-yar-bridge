OPENRESTY_PREFIX ?= /opt/homebrew/opt/openresty

PREFIX ?=          /usr/local
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

# lua-yar / lua-yar-grpc / lua-protobuf 通过 luarocks 安装到 OpenResty 标准路径，
# LUA_PATH 末尾 ;; 兜底查找。不写死 yar-group 兄弟仓库源码路径（对齐 setup-test action）。
# 本地首次运行前先：make deps（装依赖到 OpenResty luajit 标准路径）
LUA_PATH := $(LUA_PATH);;$(PWD)/lib/?.lua;$(PWD)/lib/?/init.lua;$(PWD)/t/?.lua;$(OPENRESTY_PREFIX)/luajit/share/lua/5.1/?.lua;$(OPENRESTY_PREFIX)/luajit/share/lua/5.1/?/init.lua
LUA_CPATH := $(LUA_CPATH);;$(OPENRESTY_PREFIX)/lualib/?.so;$(OPENRESTY_PREFIX)/luajit/lib/lua/5.1/?.so
export LUA_PATH LUA_CPATH

.PHONY: all test install deps lint style-check style e2e docker-e2e clean

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)$(LUA_LIB_DIR)/resty/yar_grpc_bridge
	$(INSTALL) lib/resty/yar_grpc_bridge/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty/yar_grpc_bridge

lint: style-check
	luacheck lib/

# 格式检查（CI 用）：不修改文件，仅报告差异。stylua 配置见 .stylua.toml
style-check:
	stylua --check lib/

# 格式化（本地用）：原地修改
style:
	stylua lib/

# 安装 Lua 依赖（lua-yar-grpc 连带装 lua-yar + lua-protobuf 到 OpenResty luajit 标准路径）
deps:
	luarocks --lua-dir=$(OPENRESTY_PREFIX)/luajit install lua-yar-grpc

# 删除 Test::Nginx 运行残留（servroot* nginx prefix 目录、nginx *_temp 临时目录）与测试日志
clean:
	rm -rf t/servroot* t/log *_temp

test: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -r t

e2e:
	bash t/e2e/run_e2e.sh

# Docker e2e：构建 all-in-one 镜像（OpenResty + PHP + Go + protoc）并运行端到端测试
# 用法：make docker-e2e              构建 + 运行
#       make docker-e2e ARGS=--no-cache   无缓存构建
#       make docker-e2e ARGS=--build-only  仅构建镜像
#       make docker-e2e ARGS=--run-only   仅运行已有镜像
docker-e2e:
	bash docker-test.sh $(ARGS)
