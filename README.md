# lua-resty-yar-grpc-bridge

[English](README.md) | [简体中文](README.zh.md)

[![CI](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge/actions/workflows/ci.yml)
[![Lua](https://img.shields.io/badge/Lua-%3E%3D%205.1-blue.svg)](https://www.lua.org/)
[![OpenResty](https://img.shields.io/badge/OpenResty-%3E%3D%201.19.3.1-blue.svg)](https://openresty.org/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![OPM](https://img.shields.io/badge/OPM-lua--resty--yar--grpc--bridge-blue.svg)](https://opm.openresty.org/package/fangfengxiang/lua-resty-yar-grpc-bridge/)
[![LuaRocks](https://img.shields.io/badge/dep-lua--yar--grpc-blue.svg)](https://luarocks.org/modules/fangfengxiang/lua-yar-grpc)

A bidirectional **gRPC ↔ YAR protocol bridge** for [OpenResty](https://openresty.org).

It transparently converts between the two protocols in either direction:

- **gRPC → YAR** (`grpc2yar`): receives gRPC client unary calls, converts them to YAR calls and forwards to a PHP YAR server.
- **YAR → gRPC** (`yar2grpc`): receives YAR client calls, converts them to gRPC calls and forwards to a gRPC backend.

Neither the gRPC client nor the YAR client needs any awareness of the peer protocol.

See also: [Yar](https://github.com/laruence/yar) (the most popular RPC framework in the PHP ecosystem), [lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar) (high-performance OpenResty implementation of Yar), and [Yar Protocol](https://github.com/fangfengxiang/lua-yar/blob/main/docs/protocol.md) (complete wire protocol specification).

## Features

- **Bidirectional bridging** — `grpc2yar` and `yar2grpc` are independent entry points, deployable separately.
- **Transparent conversion** — only gRPC unary calls are supported; streaming RPCs return `UNIMPLEMENTED (12)`.
- **Convention-based mapping** — no per-method config; a `services` table maps service name → `.pb` file + backend URL.
- **Pre-compiled `.pb` loading** — `pb.load()` at startup; zero `protoc` dependency at runtime.
- **Standard error-code mapping** — YAR transport / timeout / protocol errors map to gRPC status codes; gRPC status codes map back to YAR error codes.
- **Deadline propagation** — parses the `grpc-timeout` header and checks expiry before/after the call.
- **Observability** — multi-entropy request ID, `log_phase()` access log, hook passthrough (pcall-isolated).
- **Request body cap** — configurable `max_payload_bytes` (default 8 MB), Content-Length pre-check + body fallback, DoS hardening.
- **Non-blocking I/O** — outbound calls use OpenResty cosockets, never blocking the worker.
- **Host adapter layer** — `host.lua` centralizes all `ngx.*` APIs; the core protocol layer has zero `ngx.*` dependency.
- **Minimal deps** — `lua-yar` + `lua-yar-grpc` + `lua-protobuf` + OpenResty.

## Requirements

- [OpenResty](https://openresty.org) >= 1.19.3.1
- [lua-yar](https://github.com/fangfengxiang/lua-yar) >= 0.1.2 — YAR protocol library
- [lua-yar-grpc](https://github.com/fangfengxiang/lua-yar-grpc) >= 0.1.0 — gRPC ↔ YAR protocol conversion core
- [lua-protobuf](https://github.com/starwing/lua-protobuf) >= 0.3.0 — protobuf encode/decode

## Installation

```bash
# 1. Install lua-yar-grpc (auto-installs lua-yar + lua-protobuf as declared dependencies)
luarocks install lua-yar-grpc

# 2. Install this library
opm get fangfengxiang/lua-resty-yar-grpc-bridge
```

> `lua-yar-grpc`'s rockspec declares `dependencies = { lua-yar, lua-protobuf }`, so luarocks installs all three Lua deps in one shot. opm only manages OpenResty packages, so the luarocks step cannot be folded into `opm get` (opm cross-ecosystem deps are [on the opm TODO list](https://github.com/openresty/opm)).

## Quick Start

### gRPC → YAR direction (`grpc2yar`)

```nginx
http {
    lua_package_path ";;";

    # keep request body in memory, not spill to disk
    client_body_buffer_size 2m;

    init_by_lua_block {
        local bridge = require("resty.yar_grpc_bridge")

        bridge.setup {
            services = {
                Calculator = {
                    proto = "/path/to/proto/calc.pb",     -- pre-compiled .pb descriptor
                    url   = "http://127.0.0.1:8888/api",   -- YAR server address
                },
                -- UserService = {
                --     proto   = "/path/to/proto/user.pb",
                --     url     = "http://127.0.0.1:8889/api",
                --     options = { timeout = 5000 },      -- optional per-service override
                -- },
            },
            yar_options = {
                timeout          = 3000,
                connect_timeout  = 1000,
            },
            -- request body size cap (optional, default 8 MB, DoS hardening)
            max_payload_bytes = 8388608,
        }
    }

    server {
        listen 443 ssl http2;

        location / {
            content_by_lua_block {
                require("resty.yar_grpc_bridge").serve()
            }

            # access-log phase (optional, recommended)
            log_by_lua_block {
                require("resty.yar_grpc_bridge").log_phase()
            }
        }
    }
}
```

The gRPC client calls `/{Service}/{Method}` (e.g. `/Calculator/Add`); the bridge converts it to a YAR `add` call and returns the gRPC response.

### YAR → gRPC direction (`yar2grpc`)

```nginx
http {
    lua_package_path ";;";

    init_by_lua_block {
        local yar2grpc = require("resty.yar_grpc_bridge.yar2grpc")

        yar2grpc.setup {
            services = {
                Calculator = {
                    proto   = "/path/to/proto/calc.pb",
                    methods = { "Add", "Sub" },   -- gRPC method list
                },
            },
            -- inject a gRPC transport (signature: fn(service, method, payload) -> payload|nil, status, err)
            -- a typical implementation proxies via ngx.location.capture to a grpc_pass upstream
            grpc_transport = function(service, method, payload)
                local res = ngx.location.capture(
                    "/_grpc/" .. service .. "/" .. method,
                    { method = ngx.HTTP_POST, body = payload }
                )
                return res.body, nil
            end,
        }
    }

    # internal gRPC proxy location (consumed by grpc_transport's capture)
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

The YAR client points at `http://host:8888/api/{Service}` (e.g. `Calculator`) and calls `$client->method()` — the method name stays pure; the service is selected by URL path.

> Full API, naming conventions and gRPC status-code table: see [docs/api.md](docs/api.md).

## Protocol Mapping (brief)

| gRPC | YAR |
|---|---|
| `POST /{Service}/{Method}` with protobuf body | `method = {Method}` (first char lowercased) + positional params |
| gRPC status code | YAR error code (transport / timeout / protocol) |
| `grpc-timeout` header | deadline checked before & after the call |
| streaming RPC | `UNIMPLEMENTED (12)` |

**Mapping convention** — follows the PHP YAR (`Yar_Server`) idiom: register an object instance, call its public methods. The gRPC `Service` maps 1:1 to a PHP class (used only to look up the `.pb` descriptor + backend URL in `services`), and the gRPC `Method` maps to the class method name with the first char lowercased (PascalCase → camelCase, e.g. `Add` → `add`). The YAR `method` field is a **bare method name** — never `Class::method`, never `Service.Method`.

Multiple gRPC services can safely share method names (e.g. both `Calculator/Add` and `User/Add` map to YAR `add`) as long as they point to **distinct `url`s** — each service owns its own `Yar_Server` (PHP class). If two services share one `url`, `setup()` logs a `WARN` at init time.

In the `yar2grpc` direction, multiple gRPC services can share one YAR endpoint safely — the service is selected by **URL path** (`/api/{Service}`), and the YAR method stays a pure name (`$client->method()`), so identically-named methods in different services never collide. The client is fully unaware: it only points at a service-specific URL.

**Parameter mapping** — the bridge derives protobuf message type names from the gRPC Service/Method (not from the YAR method name), so the `.proto` must follow this naming convention:

| Message | Convention | Example (`Calculator.Add`) |
|---|---|---|
| Request | `{Service}_{Method}Request` | `Calculator_AddRequest` |
| Response | `{Service}_{Method}Response` | `Calculator_AddResponse` |

**Request params ↔ proto fields** — `extract_params` (gRPC→YAR) / `pack_params` (YAR→gRPC):

| Rule | Detail |
|---|---|
| ordering | proto fields sorted by **field number ascending** → YAR positional params `{ [1]=v1, [2]=v2, ... }` |
| reverse | `pack_params` maps `params[i]` → the i-th field (by field-number order) |
| proto3 scalar unset | lua-protobuf auto-fills the zero value — position preserved, no skip |
| message-type field unset | decode yields `nil` → **fail-fast** → gRPC `INVALID_ARGUMENT (3)` (prevents positional drift) |

This is why `function add($a, $b)` lines up with `message Calculator_AddRequest { int32 a = 1; int32 b = 2; }`: field number 1 → 1st param, 2 → 2nd.

**YAR retval ↔ proto Response** — `map_response` (gRPC→YAR) / `extract_result` (YAR→gRPC):

| YAR retval shape | Mapped to Response message |
|---|---|
| `nil` | empty message `{}` (e.g. `google.protobuf.Empty`) |
| scalar | `{ [field-1-by-number] = retval }` |
| indexed array (`retval[1] ~= nil`) | `{ [first repeated field] = retval }` (field 1 if repeated, else first repeated; empty msg if none) |
| associative table | used directly as the message table |

Reverse (`extract_result`): single-field Response → scalar; multi-field → table; zero-field → `nil`.

Request flow (gRPC → YAR):

```
gRPC POST /Calculator/Add  +  protobuf body
   │
   ├─ parse_grpc_path()                → Service="Calculator", Method="Add"
   ├─ method_to_yar("Add")             → "add"
   ├─ get_type_names("Calculator","Add") → Calculator_AddRequest / Calculator_AddResponse
   ├─ pb.decode(payload, "Calculator_AddRequest") → message table
   ├─ extract_params(msg, "Calculator_AddRequest") → positional params {a, b}  (by field-number order)
   ├─ Yar client:call(method="add", params={a, b})
   │        →  PHP Yar_Server(new Calculator()) :: Calculator->add(a, b)
   ├─ map_response(retval, "Calculator_AddResponse") → response message table
   └─ pb.encode(msg)                   → gRPC response payload
```

Request flow (YAR → gRPC):

```
YAR client POST /api/Calculator  (method="add", params={a, b})
   │
   ├─ nginx named capture → ngx.var.service_name="Calculator" → select _proxy_services["Calculator"] subtable
   ├─ Yar.server:handle({method, data, writer})  →  parse YAR protocol
   ├─ proxy_services["Calculator"]["add"]  →  registered at setup as Calculator/Add
   ├─ _dispatch(service="Calculator", method="Add", {a, b})
   │     ├─ get_type_names()                          → Calculator_AddRequest / Calculator_AddResponse
   │     ├─ pack_params({a,b}, "Calculator_AddRequest") → message table  (by field-number order)
   │     ├─ pb.encode + codec.encode_frame            → gRPC frame
   │     ├─ grpc_transport("Calculator", "Add", frame) → Go gRPC backend: /Calculator/Add
   │     ├─ codec.decode_frame + pb.decode            → response message table
   │     └─ extract_result(msg, "Calculator_AddResponse") → YAR retval
   └─ writer  →  YAR response  →  YAR client
```

## Architecture

Two independent entry points carry the two conversion directions. The core protocol logic (frame codec, protobuf conversion, deadline, error-code mapping) is provided by [lua-yar-grpc](https://github.com/fangfengxiang/lua-yar-grpc); this library does entry orchestration, host adaptation (`ngx.*` APIs centralized in `host.lua`) and observability (`trace.lua`).

```
gRPC → YAR direction (grpc2yar):
  ┌───────────┐  gRPC unary  ┌───────────────┐   YAR   ┌──────────────┐
  │gRPC Client│─────────────→│ grpc2yar      │────────→│ PHP YAR Server│
  │           │←─────────────│ serve()       │←────────│              │
  └───────────┘  gRPC resp   └───────────────┘ YAR resp└──────────────┘

YAR → gRPC direction (yar2grpc):
  ┌───────────┐     YAR      ┌───────────────┐  gRPC  ┌──────────────┐
  │YAR Client │─────────────→│ yar2grpc      │───────→│ gRPC Backend │
  │           │←─────────────│ handle()      │←───────│              │
  └───────────┘  YAR resp    └───────────────┘gRPC resp└──────────────┘
```

## Module Overview

```
lib/resty/yar_grpc_bridge/
├── init.lua        -- entry module: setup() / serve() / log_phase()
├── grpc2yar.lua    -- gRPC → YAR direction bridge entry
├── yar2grpc.lua    -- YAR → gRPC direction bridge entry
├── trace.lua       -- request-ID management + error-status extraction
└── host.lua        -- host adapter layer (centralizes ngx.* API)
```

> Core protocol conversion (frame codec / protobuf conversion / deadline / error codes) is provided by [lua-yar-grpc](https://github.com/fangfengxiang/lua-yar-grpc). This library only does entry orchestration + host adaptation.

## Observability

### `trace.lua`

| Function | Description |
|---|---|
| `get_request_id()` | Returns the current request ID (reads from `ngx.ctx` or generates one) |
| `ensure_request_id(header_name?)` | Extracts the request ID from a header or generates one, stored in `ngx.ctx` |
| `error_status(err_obj?)` | Extracts the error-status string from an Error object (`"ok"` / `"transport"` / `"timeout"` / ...) |

### `log_phase()`

Emits a fixed-format access log in the `log_by_lua_block` phase:

```
grpc_yar_bridge svc/method status=ok yar_latency_ms=1.234
```

### hooks passthrough

`yar_options.hooks` is forwarded to the underlying YAR client. Each hook is wrapped in an isolated `pcall`, so a hook throwing never aborts the main flow.

## Testing

```bash
make lint       # luacheck + stylua --check
make test       # Test::Nginx unit / integration tests
make e2e        # end-to-end interop (real PHP Yar ↔ Go gRPC)
```

CI matrix (`.github/workflows/ci.yml`):

| Job | Scope |
|---|---|
| **lint** | `luacheck` static analysis + `stylua --check` style consistency |
| **Test::Nginx** | `Test::Nginx::Socket::Lua` launches a real nginx + OpenResty; `content_by_lua_block` exercises the bridge. (busted is not used: this lib depends on the `ngx` API, busted runs in a plain LuaJIT CLI with no `ngx` context.) |
| **E2E (Docker)** | Real PHP Yar client ↔ OpenResty bridge ↔ Go gRPC server, both packagers (`json` / `msgpack`) × both scenarios (Scenario 1: YAR→gRPC, Scenario 2: gRPC→YAR) |

## Directory Structure

```
lua-resty-yar-grpc-bridge/
├── lib/resty/yar_grpc_bridge/   # the library
│   ├── init.lua
│   ├── grpc2yar.lua
│   ├── yar2grpc.lua
│   ├── trace.lua
│   └── host.lua
├── t/                            # Test::Nginx integration tests (*.t)
├── t/e2e/                        # end-to-end tests + Dockerfile + run_e2e.sh
├── .luacheckrc
├── Makefile                      # lint / test / e2e targets
├── dist.ini                      # OPM package metadata
└── README.md / README.zh.md      # English / Chinese README
```

## License

[Apache License 2.0](LICENSE)
