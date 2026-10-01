# 总体架构决策

## overview-1: 2 阶段架构（content + log）

**状态：** 已采纳

**决策驱动因素：** 桥接库无插件系统，Kong 式 5 阶段（rewrite/access/content/header_filter/log）是过度工程。

**背景：** 原提案 `adapt-yar-v010-phased-loading` 设计了 5 阶段拆分，参考 Kong Gateway。但 Kong 的多阶段因插件系统而生——不同插件在不同阶段执行。桥接库没有插件，5 阶段拆分带来维护复杂度和文档负担。

**思考与取舍：**
- 保留 `serve()` 在 `content_by_lua`，新增 `log_phase()` 在 `log_by_lua`
- `serve()` 内部用 `ngx.ctx` 存储元数据（service、method、status、latency）
- `log_phase()` 从 `ngx.ctx` 读取元数据，异步执行日志/指标
- 用户只需在 nginx 配置中加一行 `log_by_lua_block`，迁移成本最低

**业界参考：** Kong 的"将副作用推到 log 阶段"是直接可用的；但"插件化一切"对桥接库是反模式。

## overview-2: 模块化分层

**状态：** 已采纳

**决策驱动因素：** 关注点分离，每层可独立测试。

**背景：** 桥接需要处理 gRPC 帧编解码、YAR 协议桥接、错误映射、deadline、熔断、可观测性等多个关注点。

**思考与取舍：**
- `codec.lua` — gRPC 帧编解码（纯函数，无状态）
- `grpc2yar.lua` — YAR 协议桥接（protobuf ↔ YAR 转换）
- `errors.lua` — gRPC 状态码映射
- `deadline.lua` — gRPC deadline 解析与检查
- `trace.lua` — 请求 ID 管理 + 错误状态（入口本职观测）
- `init.lua` — Facade，组装各层

**业界参考：** lua-resty-http 的分层（http.lua + http_headers.lua + http_const.lua）。

## overview-3: persistent Client 模式

**状态：** 已采纳

**决策驱动因素：** 连接复用，避免每请求创建新 TCP 连接。

**背景：** lua-yar 0.1.0 支持 `transport.persistent = true`，缓存 `_transport` 实例。

**思考与取舍：**
- 按 service 名缓存 YAR Client 实例
- persistent 模式下无法 per-request `set_options`，deadline 只能做前后检查
- 连接失败时 lua-yar 自动清 nil 重建

**业界参考：** lua-resty-redis 的 `set_keepalive` 连接池模式。

## overview-4: hooks 驱动的横切关注点

**状态：** 已采纳

**决策驱动因素：** 可观测性不侵入核心桥接逻辑。

**背景：** lua-yar 0.1.0 提供 `hooks = { on_request, on_response }` 接口，pcall 保护。

**思考与取舍：**
- 内置 hooks（恒开，入口本职）：收集 yar_call_latency / yar_error_code 到 `ngx.ctx`，供 `log_phase` 读取
- 用户 hooks 透传：`set_hooks(opts.hooks)` 对齐 lua-yar `opts.hooks`，pcall 隔离
- hooks 引用 `ngx.ctx` 全局 table，per-request 自动隔离，persistent 复用安全

**业界参考：** grpc-gateway 的 middleware/interceptor 注入模式；lua-yar `opts.hooks` 透传。
