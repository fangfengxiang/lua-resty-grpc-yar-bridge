# API 文档

- [概览](#概览)
- [setup](#setupopts)
- [serve](#serve)
- [命名约定](#命名约定)
- [gRPC 状态码](#grpc-状态码)
- [gRPC 帧格式](#grpc-帧格式)
- [完整示例](#完整示例)

---

## 概览

本库仅暴露两个函数：

| 函数 | 调用阶段 | 作用 |
|------|----------|------|
| `setup(opts)` | `init_by_lua_block` | 加载 `.pb` 描述符、注册服务配置、注入 cosocket |
| `serve()` | `content_by_lua_block` | 处理单个 gRPC 请求的完整生命周期 |

---

## setup(opts)

**语法：**

```lua
require("resty.yar_grpc_bridge").setup(opts)
```

在 `init_by_lua_block` 阶段调用一次。完成以下初始化：

1. 加载预编译 `.pb` 二进制描述符（`pb.load()`），同一文件自动去重
2. 存储 `services` 配置表（服务名 → YAR Server URL + 选项）
3. 向 `lua-yar` 注入 OpenResty cosocket（`Yar.Client.set_socket(ngx.socket)`）
4. 配置 YAR 客户端全局默认选项

支持重复调用（热加载场景）：每次调用会清空已有缓存。

**参数 `opts`：**

| 选项 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `services` | `table` | 是 | 服务名 → `{ proto=, url=, options= }` |
| `yar_options` | `table` | 否 | YAR 客户端全局默认选项 |

**`services` 子表字段：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `proto` | `string` | 是 | `.pb` 二进制描述符文件路径 |
| `url` | `string` | 是 | YAR Server URL |
| `options` | `table` | 否 | per-service YAR 选项，覆盖 `yar_options` |

**`yar_options` / `services[].options` 常用字段：**

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `timeout` | `number` | `5000` | YAR 调用整体超时（ms） |
| `connect_timeout` | `number` | `1000` | 连接建立超时（ms） |

**返回值：** 返回模块自身（支持链式调用）。

**错误：** 参数校验失败时抛出 Lua 错误（`error()`），在 `init_by_lua_block` 中直接表现为 Nginx 启动失败。

**示例：**

```lua
local bridge = require("resty.yar_grpc_bridge")

bridge.setup {
    services = {
        Calculator = {
            proto   = "/app/proto/calc.pb",
            url     = "http://127.0.0.1:8888/api",
        },
        UserService = {
            proto   = "/app/proto/user.pb",
            url     = "http://yar-backend:8889/api",
            options = { timeout = 10000 },  -- per-service 覆盖
        },
    },
    yar_options = {
        timeout         = 3000,
        connect_timeout = 1000,
    },
}
```

---

## serve()

**语法：**

```lua
require("resty.yar_grpc_bridge").serve()
```

在 `content_by_lua_block` 阶段调用，处理单个 gRPC 请求的完整生命周期：

```
读取请求体 → 解析 gRPC 帧 → 压缩/流式检测 → 解析 path
→ 查 services → protobuf decode → YAR 调用 → 响应映射 → protobuf encode → 输出 gRPC 帧
```

**参数：** 无（配置在 `setup()` 阶段已注册）。

**返回值：** 无。通过 `ngx.exit()` 直接终止请求，成功时输出 gRPC 帧，失败时设置 `grpc-status` / `grpc-message` 响应头。

**示例：**

```nginx
location / {
    content_by_lua_block {
        require("resty.yar_grpc_bridge").serve()
    }
}
```

---

## 命名约定

`.pb` 描述符需遵循以下命名约定，桥接运行时据此自动完成 gRPC ↔ YAR 映射，无需逐方法配置：

| 要素 | 约定 | 示例 |
|------|------|------|
| gRPC path | `/{Service}/{Method}` | `/Calculator/Add` |
| Request message | `{Service}_{Method}Request` | `Calculator_AddRequest` |
| Response message | `{Service}_{Method}Response` | `Calculator_AddResponse` |
| YAR method | Method 首字母小写 | `add` |
| 请求参数 | field number → 位置参数 | field 1 → `params[1]` |
| 响应（标量） | 包装为 `{ result = retval }` | `{ result = 42 }` |
| 响应（关联数组） | field name 对齐 PHP key | `{ name = "alice" }` |
| 响应（索引数组） | 首个 `repeated` 字段名作 key | `{ items = {...} }` |

### 请求映射

gRPC Request message 的字段按 field number 升序排列，依次映射为 YAR 位置参数：

```
message Calculator_AddRequest {     YAR 调用：
    int32 a = 1;          ──────►   params[1] = a
    int32 b = 2;          ──────►   params[2] = b
}
```

### 响应映射

根据 YAR 返回值类型自动选择映射策略：

| YAR 返回值类型 | 映射策略 | 示例 |
|----------------|----------|------|
| `nil` | 空消息 `{}` | `google.protobuf.Empty` |
| 标量（`number`/`string`/`boolean`） | 包装为 `{ result = retval }` | `{ result = 42 }` |
| 索引数组（`retval[1] ~= nil`） | 首个 `repeated` 字段名作 key | `{ items = {1, 2, 3} }` |
| 关联数组 | field name 直接对齐 | `{ name = "alice", age = 30 }` |

---

## gRPC 状态码

桥接将内部错误映射为标准 gRPC 状态码（参考 [gRPC status codes](https://grpc.io/docs/guides/status-codes/)）：

| 状态 | 码 | 触发条件 |
|------|----|----------|
| `OK` | 0 | 成功 |
| `DEADLINE_EXCEEDED` | 4 | YAR 调用超时 |
| `NOT_FOUND` | 5 | 服务不在 `services` 配置中 |
| `UNIMPLEMENTED` | 12 | 流式模式或请求体含压缩标志 |
| `INTERNAL` | 13 | protobuf 编解码错误、YAR 协议错误、路径解析失败 |
| `UNAVAILABLE` | 14 | YAR 传输层错误（连接失败、响应读取失败等） |

### YAR 错误前缀映射

`lua-yar` 返回的错误信息按前缀分类映射：

| YAR 错误前缀 | gRPC 状态码 | 说明 |
|--------------|-------------|------|
| `transport:` | `UNAVAILABLE` (14) | 连接失败、网络中断 |
| `timeout:` | `DEADLINE_EXCEEDED` (4) | 连接或读取超时 |
| `protocol:` | `INTERNAL` (13) | YAR 协议解析失败 |
| 无前缀 | `INTERNAL` (13) | YAR 服务端业务错误 |

---

## gRPC 帧格式

桥接使用标准 gRPC over HTTP/2 帧格式：

```
+-------------------+---------------------------+-----------------------+
| 压缩标志 (1 byte)  | 长度 (4 bytes, 大端 uint32) |  Payload (protobuf)   |
+-------------------+---------------------------+-----------------------+
```

- **压缩标志**：`0` = 未压缩（当前唯一支持的值，非 `0` 返回 `UNIMPLEMENTED`）
- **长度**：payload 字节数，4 字节大端序无符号整数
- **Payload**：protobuf 编码的 Request/Response message

---

## 完整示例

### .proto 定义

```protobuf
syntax = "proto3";

message Calculator_AddRequest {
    int32 a = 1;
    int32 b = 2;
}

message Calculator_AddResponse {
    int32 result = 1;
}
```

### PHP YAR Server

```php
class Calculator {
    public function add($a, $b) {
        return $a + $b;
    }
}
```

### nginx 配置

```nginx
http {
    lua_package_path ";;";

    init_by_lua_block {
        require("resty.yar_grpc_bridge").setup {
            services = {
                Calculator = {
                    proto = "/app/proto/calc.pb",
                    url   = "http://127.0.0.1:8888/api",
                },
            },
        }
    }

    server {
        listen 443 ssl http2;

        location / {
            content_by_lua_block {
                require("resty.yar_grpc_bridge").serve()
            }
        }
    }
}
```

### gRPC 客户端调用

```
gRPC path: POST /Calculator/Add
请求体:    gRPC 帧（protobuf 编码的 Calculator_AddRequest{ a=1, b=2 }）
响应体:    gRPC 帧（protobuf 编码的 Calculator_AddResponse{ result=3 }）
```

桥接自动完成：`POST /Calculator/Add` → YAR `add(1, 2)` → 返回 `3` → 包装为 `Calculator_AddResponse`。
