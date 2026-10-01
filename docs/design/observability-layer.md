# 可观测性决策

## obs-1: 可组合 hooks 工厂模式（已废弃）

**状态：** 已废弃（obs-7 薄化重构替代，compose 工厂与三件套移除）

**决策驱动因素：** 可观测性需求多样（日志、指标、追踪），需可组合且互不干扰。

**背景：** 参考 lua-resty-yar 的 `observability.lua`，提供 `access_logger()`、`trace_middleware()`、`metrics_recorder()` 工厂函数。

**思考与取舍：**
- 每个工厂返回 `{ on_request, on_response }` 表，与 lua-yar hooks 接口对齐
- `compose(...)` 合并多个 hooks，每个 hook 独立 pcall 保护
- 任一 hook 异常不影响其他 hook 和主流程
- 取舍：compose 后的 hooks 在 Client 创建时注入，persistent 复用安全（hooks 引用 ngx.ctx，per-request 隔离）

**业界参考：** lua-resty-yar `observability.lua` 的 `compose(...)` 模式；Express.js 中间件的 `app.use()` 组合。

## obs-2: 请求 ID 多熵源生成

**状态：** 已采纳

**决策驱动因素：** 请求追踪需要唯一 ID，不能依赖客户端一定传 `x-request-id`。

**背景：** gRPC 客户端可能传 `x-request-id` header，也可能不传。

**思考与取舍：**
- 优先从 `x-request-id` header 提取（通过 `ngx.var.http_x_request_id`）
- 无 header 时从多熵源生成：`<timestamp> * 1000000 + <pid> * 10000 + <counter>` → 8 字符十六进制
- timestamp 提供时间唯一性，pid 提供进程唯一性，counter 提供进程内序号唯一性
- 不调用 `math.randomseed`（库不越权播种全局随机状态）
- 取舍：不是密码学安全的 UUID，但足够唯一（参考 lua-yar 的 gen_id 原则——不做模式设计，极小概率冲突是有意设计）

**业界参考：** lua-resty-yar `trace_middleware` 的多熵源模式；lua-yar 的 `gen_id` 多熵源混合 + 进程内单调递增计数器。

## obs-3: ngx.shared.DICT 指标存储（已废弃）

**状态：** 已废弃（obs-7 移除 metrics.lua，指标聚合上移框架/平台层）

**决策驱动因素：** Prometheus 指标需跨 worker 聚合，ngx.shared.DICT 是 OpenResty 的跨 worker 共享内存。

**背景：** 模块级 table 是 per-worker 的，指标需要全局聚合。

**思考与取舍：**
- 请求计数器：`grpc_yar_call_total{service="<svc>",method="<m>",status="<s>"}` → count
- 延迟直方图：`grpc_yar_duration_bucket{service="<svc>",method="<m>",le="<bucket>"}` → count（累积）
- 桶边界：`LATENCY_BUCKETS = { 1, 5, 10, 50, 100, 500, 1000, 5000 }` ms + `+Inf`
- 延迟总和：`grpc_yar_duration_sum{service="<svc>",method="<m>"}` → 累积毫秒
- 延迟计数：`grpc_yar_duration_count{service="<svc>",method="<m>"}` → 请求总数
- 无 shared dict 时静默降级（WARN 日志 + 不记录指标，不报错）
- `export()` 导出 Prometheus exposition format（`key value\n` 格式）
- 取舍：不引入 lua-resty-prometheus 依赖，用原生 shared dict + 简单计数器实现

**业界参考：** lua-resty-yar `metrics_recorder` 的 `ngx.shared.dict` 模式；Prometheus 的 histogram bucket 设计。

## obs-4: 结构化 JSON 访问日志（已废弃）

**状态：** 已废弃（obs-7 移除 log.lua，init.log_phase 固定格式访问日志替代）

**决策驱动因素：** 生产环境需要结构化日志便于 ELK/Loki 采集和查询。

**背景：** 原始 log_phase 输出简单文本行，缺少 request_id 和结构化字段。

**思考与取舍：**
- `access_logger()` hooks 工厂在 on_request 记录开始时间和参数大小，on_response 组装 JSON entry
- 零依赖 JSON 序列化：`to_json()` 内联实现，不依赖 `cjson`（避免序列化不可控类型）
- 日志字段：`ts`、`level`、`module`、`service`、`method`、`params_size`、`status`、`duration_ms`、`request_id`、`retval_size`/`error`
- `error_status()` 从 Error 对象提取状态字符串（`"ok"` / `"transport"` / `"timeout"` / ... ）

**业界参考：** lua-resty-yar `access_logger` 的 JSON 格式；Nginx 的 `log_format` 结构化日志。

## obs-5: 延迟日志模式（deferred）（已废弃）

**状态：** 已废弃（obs-7 移除 deferred 模式，log_phase 直接在 log_by_lua 输出）

**决策驱动因素：** 日志 I/O 不应阻塞响应热路径。

**背景：** `access_logger()` 默认在 `on_response` 中立即输出日志（in-request），日志 I/O 在响应热路径内。

**思考与取舍：**
- `access_logger({ defer = true })` — on_response 仅将 entry 存到 `ngx.ctx`，由 `flush_logs()` 在 log_by_lua 阶段输出
- 日志 I/O 移出响应热路径，对标 nginx access_log 的 log phase 语义
- `flush_logs()` 从 `ngx.ctx` 读取 entry 并输出，无 entry 时静默返回
- `log_phase()` 调用 `flush_logs()` 作为兜底（deferred 模式无 entry 时为 no-op）
- 取舍：deferred 模式需要 nginx 配置 `log_by_lua_block` 调用 `log_phase()`

**业界参考：** nginx access_log 的 log phase 设计；OpenResty `log_by_lua` 阶段语义。

## obs-6: 公开 API（get_request_id / ensure_request_id）

**状态：** 已采纳

**决策驱动因素：** 业务代码和日志格式化需要访问当前请求 ID。

**思考与取舍：**
- `get_request_id()` — 从 `ngx.ctx` 读取或生成 request ID（不检查 header）
- `ensure_request_id(header_name)` — 从 header 提取或生成，存入 `ngx.ctx`（供 serve() 阶段在 YAR hooks 触发前使用）
- `init.lua serve()` 调用 `ensure_request_id("x-request-id")` 消除内联重复逻辑

**业界参考：** lua-resty-yar 的公开 API 设计模式。

## obs-7: 薄化可观测性——入口本职恒开 + hooks 透传 + 不引入插件机制

**状态：** 已采纳

**决策驱动因素：**
1. bridge 内置 trace/log/metrics 三件套（~495 行）与 lua-resty-yar `observability.lua`（625 行）高度重复（函数名一一对应）
2. metrics 聚合 + Prometheus 导出属基础设施职责，越界
3. 插件机制（registry）不适合协议桥接库定位

**关联决策：** 替代 obs-1（compose 工厂）/ obs-3（shared_dict 指标）/ obs-4（JSON 访问日志）/ obs-5（deferred 日志）；obs-2（request ID 多熵源）保留；obs-6（公开 API）保留。

**背景：**
bridge v0.2.0 起，可观测性拆为 `trace.lua` / `log.lua` / `metrics.lua` 三模块，通过 `build_obs_hooks()` 组装，默认全开，经 lua-yar `opts.hooks` 注入。经评估，三模块与 lua-resty-yar 框架层 `observability.lua` 几乎同构重复（`access_logger` / `trace_middleware` / `metrics_recorder` / `compose` / `flush_logs` 函数名一一对应）。同时 `init.log_phase()` 已输出固定格式访问日志，与 `log.access_logger` 的 JSON 日志双份输出，冗余。

**思考与取舍：**

核心区分——**入口职责** vs **基础设施职责**：
- 入口职责（保留，恒开）：request ID 分配、gRPC 桥接访问日志。这是 `content_by_lua` 入口的合理输出，观测 gRPC 桥接视角（grpc_service / grpc_status / yar_latency），lua-resty-yar 的 YAR 服务端视角覆盖不到。
- 基础设施职责（移除）：metrics 聚合（shared_dict 累积计数、直方图桶、Prometheus exposition 格式）是基础设施，不是协议桥接。

> "只做一件事，并做好。"
> "Do one thing and do it well." —— Doug McIlroy, Unix philosophy

协议桥接库只做桥接，基础设施上移框架/平台。这和熔断器移除（ADR cb-1）一脉相承——机制归协议库，策略/基础设施上移。

**薄化决策：**
1. 删除 `metrics.lua`（指标聚合 + Prometheus 导出上移 lua-resty-yar / lua-resty-php-beacon）
2. 删除 `log.lua`（access_logger/flush_logs 与 init.log_phase 固定日志重复）
3. 瘦身 `trace.lua`（移除 trace_middleware/compose，保留 ensure_request_id/error_status）
4. `build_obs_hooks()` → `build_hooks()`：内置元数据收集（latency/error_code，恒开，供 log_phase 读）+ 用户 hooks 透传（pcall 隔离）

**`set_observability` 移除的理由：** 给 trace/access_log 开关就和"入口本职"定性矛盾——既是入口本职就该恒开，给开关等于承认可移除，那和 metrics 一样该上移。贯彻一致性，入口本职恒开无开关。

**不引入插件机制的理由：**
1. 定位：bridge 是协议桥接库（对标 grpc-gateway），不是框架（对标 gRPC-go/lor）。registry 是框架特征。
2. lua-yar 无插件：lua-yar 只有 hooks 回调，无 plugin/registry 概念。所谓"设置 lua-yar 插件"实为"设置 lua-yar hooks"。
3. hooks 透传已足够：`set_hooks(opts.hooks)` 顶层透传，对齐 lua-yar `opts.hooks`，用户可注入任意 hooks（含自己的 metrics_recorder）。
4. lua-resty-yar 已有 registry 插件机制，平台层也会有，bridge 再加第三套加剧碎片化。

> "简约是极致的精致。"
> "Simplicity is the ultimate sophistication." —— attributed to Leonardo da Vinci

**业界参考：**
- **grpc-gateway**（gRPC↔HTTP，最对标）：不内置 observability 实现，通过 HTTP middleware + gRPC interceptor 注入。runtime 提供扩展点但不自带 metrics/trace/log。
- **Envoy**：内置 metrics/access_log/tracing，但它是 observability-first proxy，定位不同（代理 vs 协议库）。
- **Kong/APISIX**：plugin registry 是**平台**特征，非库特征。bridge 作为库不引入。
- **grpc-go**：interceptor（unary/stream）是扩展点，stats handler 注入可观测性，但 interceptor 不是 plugin registry。

**代码评价：**
- 薄化后可观测性从 ~495 行降至 ~90 行（trace.lua 瘦身 + init.log_phase 内联）
- grpc2yar.lua `build_hooks()` 单一函数，内置收集 + 用户透传，逻辑清晰
- 用户 hooks pcall 隔离（对标 lua-resty-http pcall ngx.req.socket 模式）
- 移除 `lua_shared_dict yar_grpc_bridge_metrics` nginx 配置依赖

**知识领域：**
1. McIlroy, D. (1994). *Unix pipes and the Big Ideas*. —— "do one thing well" 原则
2. grpc-gateway runtime 设计 — gRPC↔HTTP 桥接的可观测性注入模式
3. Beyer, B. et al. (2016). *Site Reliability Engineering*, O'Reilly. Ch.6 — 监控与可观测性的分层归属
