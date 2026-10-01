# lua-resty-yar-grpc-bridge

基于 [OpenResty](https://openresty.org) 的 gRPC ↔ YAR 协议桥接库。

接收 gRPC 客户端的 Unary 请求，自动转换为 YAR 协议转发至后端 PHP YAR Server，再将 YAR 响应转回 gRPC 标准格式返回给客户端。gRPC 客户端无需感知 YAR 协议的存在。

## 特性

- **协议透明转换** — gRPC Unary 请求自动转 YAR 调用，响应自动转回 gRPC 格式（只支持 Unary 一元请求，暂不支持 gRPC stream 流式请求）
- **约定式映射** — 无需逐方法配置，仅需 `services` 表（服务名 → `.pb` 文件 + YAR Server URL）
- **预编译 .pb 加载** — 启动时通过 `pb.load()` 加载二进制描述符，运行时零 `protoc` 依赖
- **流式拒绝** — 对 Server/Client/Bidi streaming 返回 `grpc-status: 12` (UNIMPLEMENTED)
- **标准错误码映射** — YAR 传输/超时/协议错误自动映射为 gRPC 状态码；客户端参数错误返回 `INVALID_ARGUMENT(3)`
- **Deadline 传播** — 解析 `grpc-timeout` header，前后检查 deadline 是否过期
- **可观测性** — 请求 ID、结构化 JSON 访问日志、Prometheus 指标导出、deferred 日志模式，可组合 hooks
- **非阻塞 I/O** — 出向 YAR 调用走 OpenResty cosocket，不阻塞 worker
- **最小依赖** — `lua-yar` + `lua-protobuf` + OpenResty

## 快速开始

```nginx
http {
    lua_package_path ";;";

    client_body_buffer_size 2m;

    init_by_lua_block {
        local bridge = require("resty.yar_grpc_bridge")

        bridge.setup {
            services = {
                Calculator = {
                    proto = "/path/to/proto/calc.pb",
                    url   = "http://127.0.0.1:8888/api",
                },
            },
            yar_options = {
                timeout         = 3000,
                connect_timeout = 1000,
            },
        }
    }

    server {
        listen 443 ssl http2;

        location / {
            content_by_lua_block {
                require("resty.yar_grpc_bridge").serve()
            }

            log_by_lua_block {
                require("resty.yar_grpc_bridge").log_phase()
            }
        }
    }
}
```

gRPC 客户端调用 `/{Service}/{Method}`（如 `/Calculator/Add`），桥接自动转换为 YAR `add` 调用并返回 gRPC 响应。

## 安装

```bash
# 1. 安装 lua-yar
luarocks install lua-yar

# 2. 安装 lua-protobuf
luarocks install lua-protobuf

# 3. 安装本库
opm get fangfengxiang/lua-resty-yar-grpc-bridge
```

## 文档

- [API Reference](api.md)
- [Design Decisions](design/decisions.md)
- [Architecture Overview](design/overview.md)
- [与 lua-resty-yar 共存兼容性](compatibility-with-resty-yar.md)

## License

[Apache License 2.0](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge/blob/main/LICENSE)
