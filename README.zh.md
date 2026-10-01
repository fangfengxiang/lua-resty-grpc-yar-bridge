# lua-resty-yar-grpc-bridge

[English](README.md) | [简体中文](README.zh.md)

[![CI](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge/actions/workflows/ci.yml)
[![Lua](https://img.shields.io/badge/Lua-%3E%3D%205.1-blue.svg)](https://www.lua.org/)
[![OpenResty](https://img.shields.io/badge/OpenResty-%3E%3D%201.19.3.1-blue.svg)](https://openresty.org/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![OPM](https://img.shields.io/badge/OPM-lua--resty--yar--grpc--bridge-blue.svg)](https://opm.openresty.org/package/fangfengxiang/lua-resty-yar-grpc-bridge/)
[![LuaRocks](https://img.shields.io/badge/dep-lua--yar--grpc-blue.svg)](https://luarocks.org/modules/fangfengxiang/lua-yar-grpc)

基于 [OpenResty](https://openresty.org) 的 **gRPC ↔ YAR 双向协议桥接库**。

透明转换两个方向：

- **gRPC → YAR**（`grpc2yar`）：接收 gRPC 客户端 Unary 一元请求，转换为 YAR 调用转发至 PHP YAR Server。
- **YAR → gRPC**（`yar2grpc`）：接收 YAR 客户端请求，转换为 gRPC 调用转发至 gRPC 后端。

gRPC 客户端 / YAR 客户端均无需感知对端协议。

参见：[Yar](https://github.com/laruence/yar)（PHP 生态最流行的 RPC 框架）、[lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar)（Yar 的 OpenResty 高性能实现）、[Yar Protocol](https://github.com/fangfengxiang/lua-yar/blob/main/docs/protocol.md)（Yar 二进制协议完整规范）。

## 特性

- **双向协议桥接** — `grpc2yar`（gRPC→YAR）与 `yar2grpc`（YAR→gRPC）两个方向独立部署
- **协议透明转换** — 只支持 gRPC Unary 一元请求；stream 流式返回 `UNIMPLEMENTED(12)`
- **约定式映射** — 无需逐方法配置，仅需 `services` 表（服务名 → `.pb` 文件 + 后端 URL）
- **预编译 .pb 加载** — 启动时 `pb.load()` 加载二进制描述符，运行时零 `protoc` 依赖
- **标准错误码映射** — YAR 传输/超时/协议错误自动映射 gRPC 状态码；gRPC 状态码反向映射 YAR Error code
- **Deadline 传播** — 解析 `grpc-timeout` header，前后检查是否过期
- **可观测性** — 请求 ID（多熵源）+ `log_phase()` 访问日志 + hooks 透传（pcall 隔离）
- **请求体上限** — `max_payload_bytes` 可配置（默认 8MB），Content-Length 预检 + body 兜底，DoS 防护
- **非阻塞 I/O** — 出向调用走 OpenResty cosocket，不阻塞 worker
- **宿主适配层** — `host.lua` 集中 `ngx.*` API，核心协议层零 `ngx.*` 依赖
- **最小依赖** — `lua-yar` + `lua-yar-grpc` + `lua-protobuf` + OpenResty

## 运行环境

- [OpenResty](https://openresty.org) >= 1.19.3.1
- [lua-yar](https://github.com/fangfengxiang/lua-yar) >= 0.1.2（YAR 协议库）
- [lua-yar-grpc](https://github.com/fangfengxiang/lua-yar-grpc) >= 0.1.0（gRPC↔YAR 协议转换核心）
- [lua-protobuf](https://github.com/starwing/lua-protobuf) >= 0.3.0（protobuf 编解码）

## 安装

```bash
# 1. 安装 lua-yar-grpc（自动连带安装 lua-yar、lua-protobuf）
luarocks install lua-yar-grpc

# 2. 安装本库
opm get fangfengxiang/lua-resty-yar-grpc-bridge
```

> `lua-yar-grpc` 的 rockspec 已声明 `dependencies = { lua-yar, lua-protobuf }`，luarocks 一条命令即装齐三个 Lua 依赖。opm 只管 OpenResty 包，无法把 luarocks 依赖折叠进 `opm get`（opm 跨生态依赖在 [官方 TODO 列表](https://github.com/openresty/opm) 中，尚未实现）。

## 快速开始

### gRPC → YAR 方向（grpc2yar）

```nginx
http {
    lua_package_path ";;";

    # 防止请求体 spill 到磁盘
    client_body_buffer_size 2m;

    init_by_lua_block {
        local bridge = require("resty.yar_grpc_bridge")

        bridge.setup {
            services = {
                Calculator = {
                    proto = "/path/to/proto/calc.pb",     -- 预编译 .pb 描述符
                    url   = "http://127.0.0.1:8888/api",   -- YAR Server 地址
                },
                -- UserService = {
                --     proto   = "/path/to/proto/user.pb",
                --     url     = "http://127.0.0.1:8889/api",
                --     options = { timeout = 5000 },      -- 可选：per-service 覆盖
                -- },
            },
            yar_options = {
                timeout         = 3000,
                connect_timeout = 1000,
            },
            -- 请求体大小上限（可选，默认 8MB，DoS 防护）
            max_payload_bytes = 8388608,
        }
    }

    server {
        listen 443 ssl http2;

        location / {
            content_by_lua_block {
                require("resty.yar_grpc_bridge").serve()
            }

            # 访问日志阶段（可选，推荐启用）
            log_by_lua_block {
                require("resty.yar_grpc_bridge").log_phase()
            }
        }
    }
}
```

gRPC 客户端调用 `/{Service}/{Method}`（如 `/Calculator/Add`），桥接自动转换为 YAR `add` 调用并返回 gRPC 响应。

### YAR → gRPC 方向（yar2grpc）

```nginx
http {
    lua_package_path ";;";

    init_by_lua_block {
        local yar2grpc = require("resty.yar_grpc_bridge.yar2grpc")

        yar2grpc.setup {
            services = {
                Calculator = {
                    proto   = "/path/to/proto/calc.pb",
                    methods = { "Add", "Sub" },   -- gRPC method 列表
                },
            },
            -- 注入 gRPC 传输层（签名：fn(service, method, payload) -> payload|nil, status, err）
            -- 典型实现用 ngx.location.capture 内部代理到 grpc_pass upstream
            grpc_transport = function(service, method, payload)
                local res = ngx.location.capture(
                    "/_grpc/" .. service .. "/" .. method,
                    { method = ngx.HTTP_POST, body = payload }
                )
                return res.body, nil
            end,
        }
    }

    # 内部 gRPC 代理 location（供 grpc_transport 的 capture 调用）
    location /_grpc/ {
        internal;
        grpc_pass grpc://backend:50051;
    }

    server {
        listen 8888;

        # nginx location 用 named capture 把 path 末段提取为 service_name 变量，
        # 前缀由部署方决定（示例用 /api/）；lua 端读 ngx.var.service_name 不做 path 解析
        location ~ ^/api/(?<service_name>[^/]+)$ {
            content_by_lua_block {
                require("resty.yar_grpc_bridge.yar2grpc").handle()
            }
        }
    }
}
```

YAR 客户端指向 `http://host:8888/api/{Service}`（如 `Calculator`），调用 `$client->method()`——方法名保持纯名，service 由 URL path 选定。

> 完整 API、命名约定与 gRPC 状态码详见 [docs/api.md](docs/api.md)。

## 协议映射（简述）

| gRPC | YAR |
|---|---|
| `POST /{Service}/{Method}` + protobuf body | `method = {Method}`（首字母小写）+ 位置参数 |
| gRPC 状态码 | YAR Error code（transport / timeout / protocol） |
| `grpc-timeout` header | deadline 在调用前后检查 |
| streaming RPC | `UNIMPLEMENTED(12)` |

**映射约定** — 遵循 PHP YAR（`Yar_Server`）的惯用法：注册对象实例，调用其公共方法。gRPC `Service` 与 PHP 类 1:1 对应（仅用于在 `services` 表中查找 `.pb` 描述符 + 后端 URL），gRPC `Method` 映射到类方法名（首字母小写，PascalCase → camelCase，如 `Add` → `add`）。YAR `method` 字段是**纯方法名**——不是 `Class::method`，也不是 `Service.Method`。

多个 gRPC service 可以安全地复用方法名（如 `Calculator/Add` 和 `User/Add` 都映射到 YAR `add`），前提是它们指向**不同的 `url`**——每个 service 对应自己的 `Yar_Server`（PHP 类）。若两个 service 共用一个 `url`，`setup()` 在 init 阶段会输出 `WARN` 日志。

`yar2grpc` 方向，多个 gRPC service 可安全共用一个 YAR endpoint——service 由 **URL path**（`/api/{Service}`）选定，YAR method 保持纯名（`$client->method()`），不同 service 的同名 method 互不冲突。client 完全无感知：只需指向各 service 专属 URL。

**参数映射** — 桥接从 gRPC Service/Method 推导 protobuf message 类型名（而非从 YAR method 名），因此 `.proto` 必须遵循此命名约定：

| Message | 约定 | 示例（`Calculator.Add`）|
|---|---|---|
| Request | `{Service}_{Method}Request` | `Calculator_AddRequest` |
| Response | `{Service}_{Method}Response` | `Calculator_AddResponse` |

**请求参数 ↔ proto 字段** — `extract_params`（gRPC→YAR）/ `pack_params`（YAR→gRPC）：

| 规则 | 说明 |
|---|---|
| 顺序 | proto 字段按 **field number 升序** → YAR 位置参数 `{ [1]=v1, [2]=v2, ... }` |
| 逆操作 | `pack_params` 把 `params[i]` 映射到第 i 个字段（按 field-number 顺序）|
| proto3 标量未设置 | lua-protobuf 自动填零值——位置保留，不跳位 |
| message 类型字段未设置 | decode 得 nil → **fail-fast** → gRPC `INVALID_ARGUMENT(3)`（防止位置错位）|

这就是 `function add($a, $b)` 与 `message Calculator_AddRequest { int32 a = 1; int32 b = 2; }` 对齐的原因：field number 1 → 第 1 个参数，2 → 第 2 个。

**YAR retval ↔ proto Response** — `map_response`（gRPC→YAR）/ `extract_result`（YAR→gRPC）：

| YAR retval 形态 | 映射到 Response message |
|---|---|
| `nil` | 空消息 `{}`（如 `google.protobuf.Empty`）|
| 标量 | `{ [field-1-by-number] = retval }` |
| 索引数组（`retval[1] ~= nil`）| `{ [第一个 repeated 字段] = retval }`（field 1 若 repeated，否则第一个 repeated 字段；无 repeated 字段则空消息）|
| 关联数组 | 直接作为 message table |

逆操作（`extract_result`）：单字段 Response → 标量；多字段 → table；零字段 → `nil`。

请求流（gRPC → YAR）：

```
gRPC POST /Calculator/Add  +  protobuf body
   │
   ├─ parse_grpc_path()                → Service="Calculator", Method="Add"
   ├─ method_to_yar("Add")             → "add"
   ├─ get_type_names("Calculator","Add") → Calculator_AddRequest / Calculator_AddResponse
   ├─ pb.decode(payload, "Calculator_AddRequest") → message table
   ├─ extract_params(msg, "Calculator_AddRequest") → 位置参数 {a, b}  (by field-number order)
   ├─ Yar client:call(method="add", params={a, b})
   │        →  PHP Yar_Server(new Calculator()) :: Calculator->add(a, b)
   ├─ map_response(retval, "Calculator_AddResponse") → response message table
   └─ pb.encode(msg)                   → gRPC 响应 payload
```

请求流（YAR → gRPC）：

```
YAR client POST /api/Calculator  (method="add", params={a, b})
   │
   ├─ nginx named capture → ngx.var.service_name="Calculator" → 选 _proxy_services["Calculator"] 子表
   ├─ Yar.server:handle({method, data, writer})  →  解析 YAR 协议
   ├─ proxy_services["Calculator"]["add"]  →  setup 时注册为 Calculator/Add
   ├─ _dispatch(service="Calculator", method="Add", {a, b})
   │     ├─ get_type_names()                          → Calculator_AddRequest / Calculator_AddResponse
   │     ├─ pack_params({a,b}, "Calculator_AddRequest") → message table  (by field-number order)
   │     ├─ pb.encode + codec.encode_frame            → gRPC frame
   │     ├─ grpc_transport("Calculator", "Add", frame) → Go gRPC 后端: /Calculator/Add
   │     ├─ codec.decode_frame + pb.decode            → response message table
   │     └─ extract_result(msg, "Calculator_AddResponse") → YAR retval
   └─ writer  →  YAR 响应  →  YAR client
```

## 架构

两个独立入口分别承载两个方向的协议转换。核心协议逻辑（帧编解码、protobuf 转换、deadline、错误码映射）由 [lua-yar-grpc](https://github.com/fangfengxiang/lua-yar-grpc) 提供；本库负责入口编排、宿主适配（`ngx.*` API 集中在 `host.lua`）与可观测性（`trace.lua`）。

```
gRPC → YAR 方向 (grpc2yar):
  ┌───────────┐  gRPC unary  ┌───────────────┐   YAR   ┌──────────────┐
  │gRPC Client│─────────────→│ grpc2yar      │────────→│ PHP YAR Server│
  │           │←─────────────│ serve()       │←────────│              │
  └───────────┘  gRPC resp   └───────────────┘ YAR resp└──────────────┘

YAR → gRPC 方向 (yar2grpc):
  ┌───────────┐     YAR      ┌───────────────┐  gRPC  ┌──────────────┐
  │YAR Client │─────────────→│ yar2grpc      │───────→│ gRPC Backend │
  │           │←─────────────│ handle()      │←───────│              │
  └───────────┘  YAR resp    └───────────────┘gRPC resp└──────────────┘
```

## 模块结构

```
lib/resty/yar_grpc_bridge/
├── init.lua        -- 入口模块：setup() / serve() / log_phase()
├── grpc2yar.lua    -- gRPC → YAR 方向桥接入口层
├── yar2grpc.lua    -- YAR → gRPC 方向桥接入口层
├── trace.lua       -- 请求 ID 管理 + 错误状态提取
└── host.lua        -- 宿主适配层（ngx.* API 集中）
```

> 核心协议转换（帧编解码 / protobuf 转换 / deadline / 错误码）由 [lua-yar-grpc](https://github.com/fangfengxiang/lua-yar-grpc) 提供，本库只做入口编排 + 宿主适配。

## 可观测性

### trace.lua

| 函数 | 说明 |
|---|---|
| `get_request_id()` | 获取当前请求 ID（从 `ngx.ctx` 读取或生成） |
| `ensure_request_id(header_name?)` | 从 header 提取或生成请求 ID，存入 `ngx.ctx` |
| `error_status(err_obj?)` | 从 Error 对象提取错误状态字符串（`"ok"`/`"transport"`/`"timeout"`/...） |

### log_phase()

在 `log_by_lua_block` 阶段输出固定格式访问日志：

```
grpc_yar_bridge svc/method status=ok yar_latency_ms=1.234
```

### hooks 透传

`yar_options.hooks` 透传给底层 YAR Client，每个 hook 独立 `pcall` 隔离，单个 hook 抛错不影响主流程。

## 测试

```bash
make test       # Test::Nginx 单元 / 集成测试
make e2e        # 端到端互操作测试（真实 PHP Yar ↔ Go gRPC）
make lint       # luacheck + stylua --check
```

CI 矩阵（`.github/workflows/ci.yml`）：

| Job | 范围 |
|---|---|
| **lint** | `luacheck` 静态分析 + `stylua --check` 代码风格一致性 |
| **Test::Nginx** | `Test::Nginx::Socket::Lua` 启动真实 nginx + OpenResty，在 `content_by_lua_block` 跑测试。（不用 busted：本 lib 依赖 `ngx` API，busted 跑在纯 LuaJIT CLI 无 `ngx` 上下文。） |
| **E2E (Docker)** | 真实 PHP Yar 客户端 ↔ OpenResty 桥接 ↔ Go gRPC 服务端，两种打包器（`json` / `msgpack`）× 两种场景（Scenario 1: YAR→gRPC，Scenario 2: gRPC→YAR） |

## 目录结构

```
lua-resty-yar-grpc-bridge/
├── lib/resty/yar_grpc_bridge/   # 库本体
│   ├── init.lua
│   ├── grpc2yar.lua
│   ├── yar2grpc.lua
│   ├── trace.lua
│   └── host.lua
├── t/                            # Test::Nginx 集成测试（*.t）
├── t/e2e/                        # 端到端测试 + Dockerfile + run_e2e.sh
├── .luacheckrc
├── Makefile                      # lint / test / e2e 目标
├── dist.ini                      # OPM 包元数据
└── README.md / README.zh.md      # 英文 / 中文 README
```

## License

[Apache License 2.0](LICENSE)
