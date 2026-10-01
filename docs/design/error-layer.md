# 错误处理决策

## error-1: YAR Error → gRPC 状态码映射表

**状态：** 已采纳

**决策驱动因素：** YAR 错误和 gRPC 状态码是两套不同的分类体系，需映射。

**背景：** lua-yar 0.1.0 的 Error 常量：TRANSPORT/TIMEOUT/PROTOCOL/NOT_FOUND/EXCEPTION。gRPC 状态码：0/3/4/5/7/12/13/14。

**思考与取舍：**
- `_ERROR_CODE_MAP` 表驱动映射
- TRANSPORT → UNAVAILABLE(14)
- TIMEOUT → DEADLINE_EXCEEDED(4)
- PROTOCOL → INTERNAL(13)
- NOT_FOUND → NOT_FOUND(5)
- EXCEPTION → INTERNAL(13)
- 未知 code → INTERNAL(13) 兜底

**业界参考：** grpc-gateway 的 `HTTPStatusError` → gRPC status 映射。

## error-2: 双格式兼容（结构化 Error + 字符串）

**状态：** 已采纳

**决策驱动因素：** 过渡期需兼容旧版 lua-yar（字符串错误）和新版（结构化 Error 对象）。

**背景：** lua-yar 0.1.0 引入 `Error.new(code, message)` 结构化错误，但旧版返回字符串前缀（如 `"transport: ..."`）。

**思考与取舍：**
- 优先检测 `type(err) == "table" and err.code`（结构化 Error）
- 回退到字符串前缀匹配（兼容旧版和测试 mock）
- 字符串匹配：`"transport:"` / `"timeout:"` / `"protocol:"` 前缀

**业界参考：** lua-resty-redis 的错误返回 `nil, err` 字符串模式（本项目在此基础上增加结构化）。

## error-3: gRPC 错误通过 HTTP trailers 传输

**状态：** 已采纳

**决策驱动因素：** gRPC over HTTP/2 规范要求错误状态通过 trailers 传输。

**背景：** gRPC 始终返回 HTTP 200，错误信息在 `grpc-status` 和 `grpc-message` trailer/header 中。

**思考与取舍：**
- `send_error(status, message)` — 设置 `grpc-status`/`grpc-message` header，`ngx.exit(ngx.HTTP_OK)`（trailers-only 响应，无 body）
- `send_ok(frame)` — 设置 `grpc-status:0` header，输出 gRPC 帧
- content-type 始终 `application/grpc`
- **限制：** OpenResty `ngx.header` 在 `ngx.print` 后无法修改（headers 已提交），因此 `send_ok` 的 `grpc-status` 放在 headers 中而非 trailers。gRPC 客户端兼容此写法。严格的 trailer 实现需要 nginx HTTP/2 模块直接支持，OpenResty API 暂不支持。

**业界参考：** [gRPC over HTTP/2 协议规范](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md) — "Responses are always HTTP/2 status 200."

## error-4: 客户端参数错误使用 INVALID_ARGUMENT(3)

**状态：** 已采纳

**决策驱动因素：** protobuf decode 失败、gRPC path 格式错误属于客户端请求参数问题，不应使用 INTERNAL(13)。

**背景：** 原实现将所有非 YAR 错误映射为 INTERNAL(13)，无法区分服务端内部错误和客户端参数错误。

**思考与取舍：**
- protobuf decode 失败 → INVALID_ARGUMENT(3)（`grpc2yar.lua` 和 `init.lua`）
- gRPC path 格式错误 → INVALID_ARGUMENT(3)（`init.lua`）
- 服务未找到 → NOT_FOUND(5)（不变）
- protobuf encode 失败 → INTERNAL(13)（服务端序列化错误，不变）
- 取舍：INVALID_ARGUMENT 是 gRPC 标准的客户端错误码，帮助客户端区分自身问题和服务端问题

**业界参考：** gRPC 状态码规范 — "INVALID_ARGUMENT: The client specified an invalid argument."

## error-5: 新增 PERMISSION_DENIED(7) 预留

**状态：** 已采纳

**决策驱动因素：** 预留 auth hooks 扩展点，供未来认证/授权场景使用。

**思考与取舍：**
- 常量已定义但暂未在代码中使用
- 未来 auth hooks 可返回 PERMISSION_DENIED 状态码

**业界参考：** gRPC 状态码规范 — "PERMISSION_DENIED: The request does not have valid authentication credentials."
