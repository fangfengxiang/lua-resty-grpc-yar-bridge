# lua-resty-yar-grpc-bridge 项目评估报告

> 基于项目定位与目标的全维度反思评估
> 评估时间：2026-08-19
> 评估范围：lib/（7 模块）、docs/（12 文档）、openspec/（2 活跃提案 + 41 归档）、t/（9 测试）

---

## 一、项目定位审视

### 1.1 声明定位

> 基于 OpenResty 的 gRPC ↔ YAR 协议桥接库。接收 gRPC 客户端的 Unary 请求，自动转换为 YAR 协议转发至后端 PHP YAR Server，再将 YAR 响应转回 gRPC 标准格式返回给客户端。gRPC 客户端无需感知 YAR 协议的存在。

### 1.2 定位准确性评估

| 维度 | 声明 | 实际 | 评价 |
|------|------|------|------|
| 协议桥接 | gRPC ↔ YAR 双向转换 | codec + bridge 实现完整 | **准确** |
| 库而非网关 | 嵌入用户 nginx | setup() + serve() 双 API，无插件系统 | **准确** |
| Unary only | 只支持一元请求 | 流式检测返回 UNIMPLEMENTED(12) | **准确** |
| 最小依赖 | lua-yar + lua-protobuf + OpenResty | dist.ini / Makefile 确认 | **准确** |

**结论：** 项目定位声明与实现高度一致，没有过度承诺。

### 1.3 定位决策的演进轨迹

项目经历了一次关键的定位修正：

```
初始提案（5/6 阶段架构）
  └─ 参考 Kong Gateway，设计 rewrite/access/content/header_filter/log 5 阶段
  └─ 问题：桥接库无插件系统，5 阶段是过度工程

重新评测（proposal-reevaluation.md）
  └─ Kong 多阶段因插件系统而生，桥接库没有插件
  └─ log_by_lua 是唯一高价值阶段
  └─ 简化为 2 阶段（content + log）

最终实现（overview-1 ADR）
  └─ serve() 在 content_by_lua，log_phase() 在 log_by_lua
  └─ 用户迁移成本最低：加一行 log_by_lua_block
```

这个演进过程体现了**良好的自我修正能力**——不是一开始就做对，而是在深入分析后勇于推翻原方案。proposal-reevaluation.md 中对 Kong 模式的逐项分析（适用 vs 不适用）展现了跨语言调研的思考深度。

---

## 二、架构设计评估

### 2.1 模块分层

```
init.lua (Facade)
  ├── codec.lua        — gRPC 帧编解码（纯函数，无状态）
  ├── grpc2yar.lua       — YAR 协议桥接（protobuf ↔ YAR 转换）
  ├── errors.lua       — gRPC 状态码映射
  ├── deadline.lua     — gRPC deadline 解析与检查
  ├── circuit_breaker.lua — 熔断器（跨 worker 状态）
  └── observability.lua   — 可观测性（hooks 工厂模式）
```

**优点：**
- 关注点分离清晰，每层职责单一
- `codec.lua` 和 `deadline.lua` 是纯函数模块，无状态，极易测试
- `grpc2yar.lua` 是纯协议转换，不直接调用 `ngx.*` API（Kong 分析报告中确认）
- `init.lua` 作为 Facade 组装各层，对外只暴露 `setup()` + `serve()` + `log_phase()`

**反思点：**
- `grpc2yar.lua` 的 `get_client()` 函数承担了过多职责：client 创建 + 选项合并 + hooks 注入 + 熔断器集成 + 可观测性 hooks 组合。这些横切关注点本可通过 hooks 机制更松散地耦合，但当前是硬编码在 client 创建流程中。
- `init.lua` 的 `serve()` 仍是单体函数（~110 行），虽然目前可维护，但 `production-ready-optimization` 提案已识别到管线化重构的必要性。

### 2.2 2 阶段架构选择

**决策依据（overview-1 ADR）：**
- 桥接库无插件系统 → Kong 式 5 阶段是过度工程
- `log_by_lua` 是唯一高价值阶段 → 副作用推到 log 阶段
- 用户迁移成本最低 → 仅需加一行 `log_by_lua_block`

**评价：** 这是一个**正确的克制决策**。Kong 的多阶段因插件系统而生，桥接库没有插件，5 阶段拆分只会带来维护复杂度和文档负担。2 阶段（content + log）精准覆盖了核心需求：协议转换在 content，异步日志/指标在 log。

### 2.3 hooks 驱动的横切关注点

**设计（overview-4 ADR）：**
- 熔断器在 `on_response` hook 中记录成功/失败，在 `serve()` 中 `allow()` 检查
- 可观测性 hooks（trace、access_log、metrics）通过 `compose()` 组合
- hooks 引用 `ngx.ctx` 全局 table，per-request 自动隔离，persistent 复用安全

**评价：** 这是整个项目**最优雅的设计**。熔断器和可观测性完全不侵入 `grpc2yar.lua` 核心协议转换逻辑，通过 lua-yar 0.1.0 的 hooks 机制注入。`compose()` + pcall 隔离确保任一 hook 异常不影响其他 hook 和主流程。

**反思点：** hooks 注入逻辑硬编码在 `grpc2yar.lua:get_client()` 中（第 62-94 行），而非在 `init.lua:setup()` 中配置。这意味着用户无法在不修改源码的情况下自定义 hooks。如果未来需要支持用户注入自定义 hooks，需要将 hooks 配置提到 `setup()` 的 opts 中。

### 2.4 persistent Client 模式

**决策（overview-3 ADR）：**
- 按 service 名缓存 YAR Client 实例
- persistent 模式下无法 per-request `set_options` → deadline 只能做前后检查
- 连接失败时 lua-yar 自动清 nil 重建

**评价：** 正确利用了 lua-yar 0.1.0 的连接复用能力。deadline 前后检查方案是对 persistent 模式限制的合理妥协——不修改 Client timeout，只在入口和出口检查 deadline 是否过期。

**反思点：** persistent Client 的 hooks 引用 `ngx.ctx`，这在 OpenResty 中是 per-request 的。但 Client 实例是 per-service 缓存的，跨请求复用。这意味着 hooks 闭包捕获的 `ngx.ctx` 引用在每次请求时都是不同的 table——这是正确的，因为 `ngx.ctx` 在请求开始时由 OpenResty 重置。但这个安全性保证依赖于 OpenResty 的协程模型，代码注释中已说明（grpc2yar.lua:60）。

---

## 三、协议忠实性评估

### 3.1 gRPC 帧编解码（codec.lua）

**实现：**
- 5 字节帧头：1 字节压缩标志 + 4 字节大端 uint32 长度
- 自包含 `pack_u32_be` / `unpack_u32_be`，不依赖外部库
- 压缩标志非 0 → UNIMPLEMENTED(12)
- 多帧检测 → 流式模式拒绝

**评价：** 严格遵循 gRPC over HTTP/2 协议规范。自包含的大端序编解码避免了引入额外依赖。流式拒绝（UNIMPLEMENTED）是合理的边界处理。

### 3.2 gRPC ↔ YAR 映射约定

**请求映射：**
- gRPC path `/{Service}/{Method}` → YAR method（Method 首字母小写）
- Request message field number 升序 → YAR 位置参数

**响应映射：**
- nil → 空消息 `{}`
- 标量 → `{ result = retval }`
- 索引数组（`retval[1] ~= nil`）→ 首个 repeated 字段名作 key
- 关联数组 → field name 直接对齐

**评价：** 约定式映射设计消除了逐方法配置的需求，仅需 `services` 表（服务名 → .pb 文件 + YAR Server URL）。响应映射的 4 种策略覆盖了 PHP YAR 的常见返回类型。

**反思点：** 响应映射的索引数组策略依赖"首个 repeated 字段"的检测（`grpc2yar.lua:190-198`），这要求 .proto 定义中 repeated 字段的位置与 PHP 返回的索引数组语义对齐。如果 PHP 返回的索引数组与 .proto 中的 repeated 字段名不匹配，映射会出错。这个约定在 api.md 中有文档说明，但缺少运行时校验。

### 3.3 gRPC 状态码映射（errors.lua）

**映射表：**
- `Yar.Error.TRANSPORT` → `UNAVAILABLE(14)`
- `Yar.Error.TIMEOUT` → `DEADLINE_EXCEEDED(4)`
- `Yar.Error.PROTOCOL` → `INTERNAL(13)`
- `Yar.Error.NOT_FOUND` → `NOT_FOUND(5)`
- `Yar.Error.EXCEPTION` → `INTERNAL(13)`

**评价：** 错误分类合理。传输错误→UNAVAILABLE（后端不可达），超时→DEADLINE_EXCEEDED（时间限制），协议错误→INTERNAL（解析失败）。

**反思点：** `errors.lua` 的 gRPC trailer 处理是一个已知问题。当前代码将 `grpc-status` 和 `grpc-message` 放在 response headers 中，而 gRPC over HTTP/2 规范要求放在 trailers 中。代码注释（errors.lua:83-85）已说明 OpenResty API 的限制——`ngx.header` 在 `ngx.print` 后无法修改，严格的 trailer 实现需要 nginx HTTP/2 模块直接支持。ddd-bdd 提案中提出了用 `ngx.eof()` 分离 headers/body 的方案，但风险评估为 Medium（test-nginx 可能不支持 trailers）。

---

## 四、韧性设计评估

### 4.1 熔断器（circuit_breaker.lua）

**设计：**
- 3 态状态机：CLOSED → OPEN → HALF_OPEN → CLOSED
- 跨 worker 状态：`ngx.shared.DICT` 存储
- 无 shared dict 时降级到模块级 table
- 仅 TRANSPORT/TIMEOUT 错误触发失败计数（协议错误是客户端 bug）

**评价：** 状态机设计完整，降级策略合理。HALF_OPEN 探测限制（`half_open_max`）已在当前代码中实现（circuit_breaker.lua:162-169），ddd-bdd 提案中提到的 bug 已修复。

**反思点：**
- 熔断器没有 L1 缓存（worker 级 table），每次 `allow()` 都直接访问 shared dict。在高 QPS 场景下，shared dict 的锁竞争可能成为瓶颈。Kong 分析报告中提出了 L1/L2 方案（worker 级 table + TTL 1s + shared dict），但当前未实现。
- 熔断器的 `record_failure` 在 `on_response` hook 中调用，hook 内部有 pcall 保护。但 `record_failure` 自身访问 shared dict 时如果出错（如 dict 被意外删除），错误会被 hook 的 pcall 捕获并 log，不会影响主流程——这是正确的。

### 4.2 Deadline（deadline.lua）

**设计：**
- 解析 `grpc-timeout` header（格式：`<value><unit>`，unit: H/M/S/m/u/n）
- 前置检查：serve 入口，若已过期 → DEADLINE_EXCEEDED
- 后置检查：YAR 调用返回后，若超时 → DEADLINE_EXCEEDED
- 不修改 Client timeout（persistent 模式无法 per-request set_options）

**评价：** 前后检查方案是对 persistent Client 限制的合理妥协。`check_front` 和 `check_back` 已统一为 `check_expired`（ddd-bdd 提案中的重复代码问题已修复）。

**反思点：** 前后检查有一个盲区——YAR 调用本身的超时。如果 gRPC deadline 是 2s，但 YAR Client 的 timeout 是 5s，那么 YAR 调用可能在 deadline 过期后仍在执行。后置检查会发现超时并返回 DEADLINE_EXCEEDED，但 YAR 调用已经浪费了 3s 的资源。proposal-reevaluation.md 中讨论了这个问题，结论是不修改 Client timeout，因为 persistent 模式下无法 per-request `set_options`。这是 persistent 模式的固有限制，在当前架构下是可接受的。

---

## 五、可观测性评估

### 5.1 hooks 工厂模式（observability.lua）

**设计：**
- `trace_middleware()` — 请求 ID 生成/提取
- `access_logger()` — 结构化 JSON 访问日志（支持 deferred 模式）
- `metrics_recorder()` — ngx.shared.DICT 计数器 + 延迟直方图 + export()
- `compose()` — 组合多个 hooks，pcall 隔离
- `flush_logs()` — log_by_lua 阶段输出延迟日志

**评价：** 可组合 hooks 工厂模式设计优雅，对标 lua-resty-yar 的 observability.lua。deferred 日志模式将 I/O 移出响应热路径，对标 nginx access_log 的 log phase 语义。Prometheus 指标导出支持延迟直方图（8 个桶边界）。

**反思点：**
- `to_json()` 是自实现的简易 JSON 序列化，仅支持扁平 table（string/number/boolean/nil 值）。如果日志 entry 中出现嵌套 table（如 params 是数组），`to_json()` 会将其 `tostring(v)` 处理，输出格式不标准。生产环境可能需要更完整的 JSON 处理。
- `metrics_recorder` 的 `export()` 使用 `dict:get_keys(0)` 遍历所有 key，在高基数场景下（大量 service/method 组合）可能有性能问题。可以考虑缓存 key 列表或使用独立的指标注册表。

### 5.2 请求 ID 生成

**设计：**
- 多熵源混合：ngx.time（秒级时间）+ ngx.worker.pid（进程区分）+ 计数器（进程内单调递增）
- 8 字符十六进制格式
- 从 `x-request-id` header 提取或自动生成
- 库不越权播种（不调用 math.randomseed）

**评价：** 遵循了 lua-yar 的设计原则（Tieske/uuid 业界标杆库）——随机种子是全局数据，设置它是应用层职责。多熵源混合比 PHP Yar 的 php_mt_rand() 和 yar-c 的硬编码 id=1000 都更健壮。

---

## 六、代码质量评估

### 6.1 优点

- **模块级缓存设计合理** — 类型名、字段排序、索引字段映射、Client 实例均缓存，避免每请求重复计算
- **双语注释** — 中文在前英文在后，符合项目规范，LSP 注解连续不被打断
- **LuaLS 类型注解** — 逐步添加 `---@class`/`---@param`/`---@return`
- **Lua OOP 惯例** — 遵循 `Class.__index = Class` + `setmetatable(obj, Class)` 模式
- **错误处理分层** — 内部层用 nil, err 字符串；client:call() 返回结构化 Error 对象

### 6.2 反思点

- `init.lua` 的 `serve()` 中，`ngx.ctx.grpc_status` 的设置散落在各错误路径（9 处），缺少统一的状态管理。可以考虑在 `errors.send_error` 中统一设置 `ngx.ctx.grpc_status`。
- `grpc2yar.lua:get_client()` 中 hooks 注入是硬编码的，用户无法在不修改源码的情况下自定义 hooks。如果未来需要支持用户注入自定义 hooks，需要将 hooks 配置提到 `setup()` 的 opts 中。
- `observability.lua:to_json()` 不处理嵌套 table，可能导致日志格式不标准。
- `errors.lua` 的 gRPC trailer 处理是已知技术债务，受限于 OpenResty API。

---

## 七、测试覆盖评估

### 7.1 测试文件

| 文件 | 覆盖模块 | 测试数 |
|------|----------|--------|
| bridge.t | grpc2yar.lua | — |
| codec.t | codec.lua | — |
| errors.t | errors.lua | — |
| deadline.t | deadline.lua | 10 |
| circuit_breaker.t | circuit_breaker.lua | 8 |
| observability.t | observability.lua | 10 |
| error-scenarios.t | 错误场景集成 | — |
| integration.t | 端到端集成 | — |
| streaming.t | 流式拒绝 | — |

### 7.2 反思点

- 缺少 OpenResty 端到端集成测试（提案中已识别）——cosocket 注入、连接池参数透传等关键路径零验证
- 熔断器在真实请求流中的集成测试缺失
- gRPC trailer 处理的测试可能受限于 test-nginx 框架能力

---

## 八、文档质量评估

### 8.1 优点

- **28 个 ADR 设计决策** — 覆盖 7 个模块，遵循 ADR 骨架（状态 + 决策驱动因素 + 关联决策 + 背景 + 思考与取舍 + 业界参考 + 代码评价）
- **README + api.md** — 完整的使用文档，含快速开始、API 签名、命名约定、gRPC 状态码、帧格式、完整示例
- **CHANGELOG** — 遵循 Keep a Changelog 规范，语义化版本
- **Kong 架构对照分析** — 跨语言调研的思考深度，逐项分析适用性
- **proposal-reevaluation.md** — 自我修正过程的完整记录

### 8.2 反思点

- 文档间存在历史演进痕迹——`optimization-plan-yar-0.1.0.md` 仍保留 6 阶段设计，`proposal-reevaluation.md` 简化为 2 阶段，`kong-architecture-analysis.md` 提出 P0-P3 优化项。新读者可能困惑哪些已实现、哪些是计划。
- openspec 中有 41 个已归档提案 + 2 个活跃提案，变更历史丰富但也增加了理解成本。
- `docs/design/` 的 28 个 ADR 与 `openspec/changes/` 的提案之间存在部分内容重复。

---

## 九、总体评估

### 9.1 核心优势

1. **定位准确** — 明确是"库"不是"网关"，拒绝了 Kong 式的插件化、5 阶段拆分等过度工程
2. **架构演进能力强** — 从 5 阶段到 2 阶段的自我修正，体现了良好的判断力
3. **设计文档完善** — 28 个 ADR 记录了关键决策的思考过程，跨语言调研深度
4. **横切关注点处理优雅** — hooks 驱动模式不侵入核心逻辑，compose + pcall 隔离
5. **协议忠实** — gRPC 帧编解码和 YAR 协议桥接严格遵循规范

### 9.2 改进空间

1. **`serve()` 管线化重构** — 提案已识别，当功能持续增加时 ROI 将提升
2. **gRPC trailer 处理** — 已知技术债务，受限于 OpenResty API
3. **可观测性增强** — `to_json()` 嵌套 table 支持、指标导出性能优化
4. **端到端集成测试** — cosocket 注入、连接池、熔断器真实流验证
5. **hooks 配置外提** — 将 hooks 注入从 `grpc2yar.lua` 硬编码提到 `setup()` opts
6. **文档清理** — 消除历史演进痕迹，明确标注已实现 vs 计划

### 9.3 项目成熟度

| 维度 | 评分（5 分制） | 说明 |
|------|---------------|------|
| 定位清晰度 | 5 | 声明与实现高度一致，无过度承诺 |
| 架构设计 | 4 | 模块分层清晰，2 阶段选择正确，hooks 设计优雅 |
| 协议忠实性 | 5 | gRPC/YAR 协议实现严格遵循规范 |
| 韧性设计 | 4 | 熔断器完整，deadline 前后检查合理，L1 缓存可改进 |
| 可观测性 | 4 | hooks 工厂模式优雅，JSON 序列化和指标导出可增强 |
| 代码质量 | 4 | 缓存设计合理，双语注释，serve() 可管线化 |
| 测试覆盖 | 3 | 核心模块有测试，端到端集成测试缺失 |
| 文档质量 | 4 | 28 ADR + 完整 API 文档，历史演进痕迹可清理 |

**综合评分：4.1/5** — 一个定位清晰、架构合理、工程化程度高的协议桥接库，已具备生产可用的核心能力，在可观测性、测试覆盖和文档清理方面有明确的改进路径。
