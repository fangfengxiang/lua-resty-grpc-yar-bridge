# 帧编解码决策

## codec-1: 自包含大端 uint32 编解码

**状态：** 已采纳

**决策驱动因素：** gRPC 帧头长度字段是 4 字节大端 uint32，不依赖外部库。

**背景：** Lua 标准库无 `string.pack`/`string.unpack`（Lua 5.1），OpenResty 的 LuaJIT 也无。

**思考与取舍：**
- `pack_u32_be(n)` — 用 `math.floor` 分字节 + `string.char` 拼接
- `unpack_u32_be(s, offset)` — 用 `string.byte` 取 4 字节 + 乘法累加
- 不引入 `lua-struct` 或 `lua-bitop` 依赖

**业界参考：** lua-resty-websocket 的 `bit.tohex` 模式；本项目选择更简单的纯算术实现。

## codec-2: 5 字节帧头固定结构

**状态：** 已采纳

**决策驱动因素：** gRPC over HTTP/2 协议规范定义的帧头格式。

**背景：** gRPC 帧头 = 1 字节压缩标志 + 4 字节大端长度。

**思考与取舍：**
- `FRAME_HEADER_SIZE = 5` 常量
- `COMPRESSION_NONE = 0` 常量
- 帧头 + payload = 完整帧

**业界参考：** [gRPC over HTTP/2 协议规范](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)

## codec-3: 流式模式检测

**状态：** 已采纳

**决策驱动因素：** 桥接仅支持 Unary RPC，流式（多帧）需拒绝。

**背景：** gRPC 支持 Unary、Server Streaming、Client Streaming、Bidirectional Streaming。后三者在一个 HTTP/2 请求体中包含多个 gRPC 帧。

**思考与取舍：**
- `has_multiple_frames(body, first_frame_size)` — 检测 body 是否超过第一个帧的大小
- 检测到多帧时返回 `UNIMPLEMENTED` (gRPC 12)
- 简单有效，不需要完整解析所有帧

**业界参考：** grpc-gateway 的 Unary-only 代理模式。
