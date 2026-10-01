# Kong 架构思想对照分析

> 本报告由 `lua-resty-yar-grpc-bridge` 项目发起，参考 [Kong Gateway](https://github.com/Kong/kong) 的架构设计理念，审视本项目的工程化优化空间。
>
> Kong 是基于 OpenResty/Nginx 的 API 网关，其核心设计模式包括：插件化 PDK、分阶段生命周期、上下文对象、L1/L2 缓存、Upstream/Target 负载均衡模型、主动/被动健康检查。本报告逐一对照分析这些模式在本项目中的适用性和优化点。

---

## 一、Kong 核心设计模式概览

| # | 设计模式 | Kong 实现 | 核心价值 |
|---|----------|-----------|----------|
| 1 | 插件化 PDK | `kong.pdk.*`，插件按优先级在各阶段执行 | 可扩展、可插拔 |
| 2 | 分阶段生命周期 | rewrite → access → balancer → header_filter → body_filter → log | 关注点分离 |
| 3 | 上下文对象 | `kong.ctx.shared`，贯穿整个请求生命周期 | 数据流转清晰 |
| 4 | L1/L2 缓存 | worker 级 Lua table (L1) + `ngx.shared.DICT` (L2) | 跨 worker 一致性 |
| 5 | Upstream/Target 模型 | Service → Upstream (LB pool) → Target (物理实例) | 负载均衡、故障转移 |
| 6 | 主动健康检查 | `ngx.timer.every` 定期探测上游 | 自动发现故障节点 |
| 7 | 被动健康检查 | 观察实际请求失败率，自动标记不健康 | 零开销故障感知 |
| 8 | 熔断器 | 连续失败达阈值后隔离 Target | 防止雪崩 |
| 9 | 声明式配置 | YAML declarative config，热加载 | 运维友好 |
| 10 | 可观测性 | 内置 logging/prometheus/statsd 等插件 | 生产可观测 |

---

## 二、逐项对照分析

### 1. 插件化 / 中间件管线 (PDK)

**Kong 做法**：核心极简，所有功能（认证、限流、日志、指标）都是插件，按 `PRIORITY` 排序在各阶段执行。插件通过 PDK 访问核心能力，不直接操作 Nginx API。

**当前实现**：`serve()` 是单体函数，所有逻辑内联：

```lua
-- init.lua serve() 当前结构（229 行，全部内联）
function _M.serve()
    -- 1. 读取请求体
    -- 2. 解析 gRPC 帧
    -- 3. 压缩标志检查
    -- 4. 流式模式检测
    -- 5. 解析 gRPC path
    -- 6. 查 services
    -- 7. 调用 bridge.handle（pcall 包裹）
    -- 8. 输出成功响应
end
```

**问题**：
- 新增功能（日志、熔断、指标）必须修改 `serve()` 函数体
- 无法独立启用/禁用某个功能
- 测试需 mock 整个 `serve()`，无法单独测试某个阶段
- `ngx.*` API 调用散落在各模块中，无抽象层

**Kong 启发的优化**：引入中间件管线模式（轻量版插件系统）

```lua
-- lib/resty/yar_grpc_bridge/pipeline.lua
local pipeline = {
    -- 每个 handler 接收 ctx，可短路返回 error
    { name = "read_body",      phase = "access",  handler = read_body },
    { name = "decode_frame",    phase = "access",  handler = decode_frame },
    { name = "check_compression", phase = "access", handler = check_compression },
    { name = "check_streaming", phase = "access",  handler = check_streaming },
    { name = "parse_path",      phase = "access",  handler = parse_path },
    { name = "resolve_service", phase = "access",  handler = resolve_service },
    { name = "check_circuit",    phase = "access",  handler = check_circuit_breaker },  -- 可插拔
    { name = "parse_deadline",  phase = "access",  handler = parse_grpc_deadline },    -- 可插拔
    { name = "protocol_bridge", phase = "content", handler = bridge.handle },
    { name = "log_request",     phase = "log",     handler = log_request },            -- 可插拔
    { name = "record_metrics",  phase = "log",     handler = record_metrics },         -- 可插拔
}

function _M.run(ctx)
    for _, step in ipairs(pipeline) do
        local ok, err = step.handler(ctx)
        if not ok then
            return errors.send_error(err.status, err.message)
        end
    end
end
```

**收益**：新增功能只需添加一个 pipeline step，不修改核心流程；可按需启用/禁用；每个 step 可独立测试。

**必要性**：中。当前 `serve()` 仅 70 行（229 行含注释和 setup），单体尚可维护。但当 OpenSpec 提案中的 5 项改进全部落地后，`serve()` 将膨胀到 120+ 行，届时管线化重构的 ROI 将显著提升。

**建议优先级**：P2（在 OpenSpec 提案落地后重构）

---

### 2. 分阶段生命周期 (Nginx Phases)

**Kong 做法**：显式利用 Nginx 的多个 phase，不同关注点分布在不同 phase：
- `rewrite_by_lua` — 路径解析、URL 重写
- `access_by_lua` — 认证、限流、熔断检查
- `balancer_by_lua` — 上游选择
- `header_filter_by_lua` — 响应头处理
- `body_filter_by_lua` — 响应体处理
- `log_by_lua` — 日志、指标（请求完成后异步执行）

**当前实现**：全部逻辑集中在 `content_by_lua_block`：

```nginx
location / {
    content_by_lua_block {
        require("resty.yar_grpc_bridge").serve()
    }
}
```

**问题**：
- 日志和指标在 `content_by_lua` 中执行，增加请求延迟（应在 `log_by_lua` 中异步执行）
- 熔断检查、deadline 解析等前置检查与协议转换混在一起
- 无法在 `header_filter` 阶段统一设置 gRPC 响应头

**Kong 启发的优化**：拆分到多个 Nginx phase

```nginx
location / {
    rewrite_by_lua_block {
        require("resty.yar_grpc_bridge").rewrite()   -- 解析 path、解析 service
    }
    access_by_lua_block {
        require("resty.yar_grpc_bridge").access()    -- 熔断检查、deadline 解析、body 读取
    }
    content_by_lua_block {
        require("resty.yar_grpc_bridge").content()   -- 协议转换（protobuf ↔ YAR）
    }
    header_filter_by_lua_block {
        require("resty.yar_grpc_bridge").header_filter()  -- 统一设置 gRPC 响应头
    }
    log_by_lua_block {
        require("resty.yar_grpc_bridge").log_phase()  -- 日志、指标（异步，不影响延迟）
    }
}
```

**关键收益**：
- `log_by_lua` 在响应发送给客户端**之后**执行，日志和指标记录不增加请求延迟
- `access_by_lua` 可以在协议转换前短路（熔断、deadline 过期），避免不必要的 protobuf 解码
- `header_filter` 统一管理 gRPC 响应头，避免 `errors.lua` 中分散的 `ngx.header` 设置

**必要性**：高。`log_by_lua` 的异步特性对生产环境延迟优化至关重要。

**建议优先级**：P1

---

### 3. 上下文对象 (ctx)

**Kong 做法**：`kong.ctx.shared` 是一个 table，贯穿整个请求生命周期，各阶段/插件向其中写入数据，后续阶段读取。避免函数间传递大量参数。

**当前实现**：`serve()` 使用局部变量，`bridge.handle()` 接收 4 个参数：

```lua
-- 当前：ad-hoc 局部变量 + 多参数传递
function _M.serve()
    local body = ngx.req.get_body_data()
    local flag, payload, frame_size, err = codec.decode_frame(body)
    local path = ngx.var.uri
    local service, method = bridge.parse_grpc_path(path)
    local url, svc_opts = resolve_service_config(service)
    -- ...
    bridge.handle(service, method, payload, { url=url, options=svc_opts })
end

function _M.handle(service, method, payload, service_config)
    -- 4 个参数，新增字段需改函数签名
end
```

**问题**：
- 新增字段（如 `request_id`、`deadline_ms`、`circuit_breaker_state`）需修改函数签名
- 日志记录需要分散在各处的变量，无法在请求结束时统一记录
- `bridge.handle` 的 4 参数在扩展时不够灵活

**Kong 启发的优化**：引入 ctx 上下文对象

```lua
-- lib/resty/yar_grpc_bridge/context.lua
local _M = {}

function _M.new()
    return {
        -- 请求元数据
        request_id  = nil,       -- 从 x-request-id header 或自动生成
        start_time  = ngx.now(), -- 请求开始时间（用于延迟计算）
        
        -- gRPC 请求信息
        path        = nil,       -- ngx.var.uri
        service     = nil,       -- 解析出的服务名
        method      = nil,       -- 解析出的方法名
        yar_method  = nil,       -- YAR 方法名（首字母小写）
        payload     = nil,       -- protobuf 编码的请求 payload
        frame_size  = nil,       -- gRPC 帧大小
        
        -- 服务配置
        yar_url     = nil,       -- YAR Server URL
        yar_opts    = nil,       -- 合并后的 YAR 选项（含 deadline）
        
        -- 响应信息
        response_payload = nil,  -- protobuf 编码的响应 payload
        grpc_status  = 0,        -- gRPC 状态码
        error_msg    = nil,      -- 错误信息
        
        -- 可观测性
        latency_ms  = nil,       -- 请求总延迟
        yar_latency_ms = nil,    -- YAR 调用延迟
    }
end

return _M
```

**使用方式**：

```lua
function _M.serve()
    local ctx = context.new()
    ctx.request_id = get_request_id()
    
    -- 各阶段操作 ctx，不传参
    decode_frame(ctx)        -- ctx.payload = ...
    parse_path(ctx)          -- ctx.service, ctx.method = ...
    resolve_service(ctx)     -- ctx.yar_url, ctx.yar_opts = ...
    bridge.handle(ctx)       -- ctx.response_payload = ...
    
    -- 请求结束时，ctx 包含所有信息，便于统一日志
    log_request(ctx)         -- rid=.. svc=.. method=.. status=.. latency=..
end
```

**收益**：
- 新增字段只需在 ctx 中添加，不改函数签名
- 请求结束时 ctx 包含完整信息，日志/指标一次性记录
- 便于在 `log_by_lua` 阶段使用（ctx 可存入 `ngx.ctx`）

**必要性**：高。当落地 OpenSpec 提案中的结构化日志和指标时，ctx 对象是基础设施。

**建议优先级**：P0（与结构化日志同步落地）

---

### 4. L1/L2 缓存策略

**Kong 做法**：
- L1：worker 级 Lua table（`kong.cache.l1`），无锁，最快
- L2：`ngx.shared.DICT`（`kong.cache.l2`），跨 worker 共享，有锁
- 读取顺序：L1 → L2 → 源（DB/配置）
- L1 通过 worker events 订阅 L2 变更通知，自动失效

**当前实现**：全部使用模块级 Lua table（L1 only）：

```lua
-- init.lua
local _svc_cache = {}         -- L1 only
-- grpc2yar.lua
local _sorted_fields_cache = {}  -- L1 only
local _idx_fields_cache = {}     -- L1 only
local _type_cache = {}           -- L1 only
```

**问题分析**：

| 缓存 | 数据性质 | L1 only 是否足够？ |
|------|----------|-------------------|
| `_svc_cache` | 静态配置（setup 后不变） | ✅ 足够 |
| `_sorted_fields_cache` | pb 元数据（进程内不变） | ✅ 足够 |
| `_idx_fields_cache` | pb 元数据（进程内不变） | ✅ 足够 |
| `_type_cache` | 类型名字符串拼接（不变） | ✅ 足够 |
| 熔断器状态（未来） | 动态状态（运行时变化） | ❌ 需 L2 |

**结论**：当前 4 个缓存全部是只读静态数据，L1 only 完全正确，无需引入 L2。

**但 OpenSpec 提案中的熔断器需要 L2**：

```lua
-- 熔断器状态需跨 worker 一致
-- 如果只用 L1，worker A 熔断了 backend-x，worker B 不知道，继续发请求

-- Kong 启发的 L1/L2 方案
local shared = ngx.shared.grpc_yar_cb  -- L2: nginx 配置 lua_shared_dict

local function get_state(url)
    -- L1: worker 级缓存（带 TTL，避免频繁访问 L2）
    local l1 = _l1_cache[url]
    if l1 and l1.expire > ngx.now() then
        return l1.state
    end
    -- L2: shared dict
    local state = shared:get(url .. ":state")
    local fail_count = shared:get(url .. ":fail") or 0
    local open_time = shared:get(url .. ":open_time") or 0
    
    -- 回填 L1（TTL 1s，平衡一致性和性能）
    _l1_cache[url] = { state = state, fail = fail_count, expire = ngx.now() + 1 }
    
    return state, fail_count, open_time
end
```

**必要性**：中。熔断器 L1 only 也能工作（每个 worker 独立熔断），但会导致 worker 间状态不一致，熔断不精确。生产环境建议 L2。

**建议优先级**：P2（熔断器落地时同步考虑）

---

### 5. Upstream / Target 负载均衡模型

**Kong 做法**：
- **Service**：逻辑服务（如 "Calculator"）
- **Upstream**：负载均衡池（虚拟主机名，承载 LB 算法和健康检查配置）
- **Target**：物理实例（IP:Port + weight）
- 支持 round-robin、consistent hashing、least connections、latency-based 等算法

**当前实现**：1:1 服务→URL 映射，无负载均衡：

```lua
services = {
    Calculator = {
        proto = "proto/calc.pb",
        url   = "http://127.0.0.1:8888/api",  -- 单一后端
    },
}
```

**问题**：
- 单点故障：YAR Server 宕机，该服务完全不可用
- 无法水平扩展 YAR 后端
- 无故障转移能力

**Kong 启发的优化**：引入 Upstream 池

```lua
services = {
    Calculator = {
        proto = "proto/calc.pb",
        -- 方式 1：单一 URL（向后兼容，当前行为）
        url = "http://127.0.0.1:8888/api",
        
        -- 方式 2：Upstream 池（新增，多后端负载均衡）
        upstream = {
            { url = "http://yar1:8888/api", weight = 5 },
            { url = "http://yar2:8888/api", weight = 3 },
            { url = "http://yar3:8888/api", weight = 2 },
        },
        -- 可选：LB 策略
        balancer = "round_robin",  -- 或 "least_connections"
    },
}
```

**实现方案**：

```lua
-- lib/resty/yar_grpc_bridge/balancer.lua
local _M = {}

-- 轮询（加权）
function _M.round_robin(targets)
    -- 使用 ngx.shared.DICT 维护游标（跨 worker）
    -- 或用 worker 级 table + 请求计数（简单方案）
end

-- 最少连接
function _M.least_connections(targets)
    -- 跟踪每个 target 的 in-flight 请求数
    -- 用 ngx.shared.DICT 计数
end

-- 主动健康检查
function _M.health_check_loop()
    -- ngx.timer.every 定期探测各 target
    -- 标记不健康 target，balancer 跳过
end

return _M
```

**必要性**：中。取决于业务场景。如果 YAR 后端只有单实例，不需要。如果有多实例（如 Kubernetes 部署），强烈建议。

**建议优先级**：P2（多后端场景需要时实现）

---

### 6. 主动健康检查

**Kong 做法**：`ngx.timer.every` 定期向上游发送探测请求，根据响应判断健康状态。不健康节点自动从负载均衡池中移除，恢复后自动加回。

**当前实现**：无主动健康检查。被动感知依赖熔断器（OpenSpec 提案中已规划）。

**问题**：
- 被动健康检查（熔断器）需要先经历 N 次失败才熔断
- 主动健康检查可以在后端恢复后第一时间发现，缩短 HALF_OPEN → CLOSED 时间
- 对于已宕机的后端，主动探测可以提前发现恢复

**Kong 启发的优化**：

```lua
-- lib/resty/yar_grpc_bridge/health_check.lua
local _M = {}

-- 在 init_worker 阶段启动
function _M.start(upstreams)
    ngx.timer.every(5, function()
        for url, targets in pairs(upstreams) do
            for _, target in ipairs(targets) do
                -- 发送一个轻量 YAR ping 请求
                local ok = probe(target.url)
                -- 更新 shared dict 中的健康状态
                ngx.shared.grpc_yar_health:set(
                    target.url, 
                    ok and "healthy" or "unhealthy"
                )
            end
        end
    end)
end

local function probe(url)
    -- 创建临时 YAR client，调用一个轻量方法（如 ping）
    -- 超时设为 1s，不影响正常请求
    local client = Yar.Client.new(url)
    client:set_options({ timeout = 1000 })
    local _, err = client:call("ping", {})
    return err == nil
end

return _M
```

**必要性**：低。对于协议桥接库，被动健康检查（熔断器）通常足够。主动健康检查更适合网关场景。

**建议优先级**：P3（可选增强）

---

### 7. 被动健康检查 / 熔断器

**Kong 做法**：观察实际请求结果，连续失败达阈值后自动隔离 Target。与主动健康检查配合使用。

**当前状态**：已在 OpenSpec 提案 `bridge-observability-resilience` 中规划（P1）。

**Kong 启发的增强**：Kong 的被动健康检查不仅看失败次数，还看**失败率**（如最近 100 个请求中失败超过 50%）。我们的提案只看连续失败次数，可以增强为滑动窗口失败率：

```lua
-- Kong 启发：滑动窗口失败率（而非仅连续失败计数）
-- 参数增强：
-- failures_threshold = 5          -- 连续失败 5 次（已有）
-- failure_rate_threshold = 0.5    -- 滑动窗口失败率 50%（新增）
-- sliding_window_size = 100       -- 滑动窗口大小 100 个请求（新增）
```

**建议**：先实现连续失败计数（简单有效），后续按需增强为滑动窗口。

---

### 8. 声明式配置 / 热加载

**Kong 做法**：
- 声明式 YAML 配置（`kong.yml`），支持 `kong reload` 热加载
- Admin API 动态增删改查
- 配置变更通过 worker events 传播到所有 worker

**当前实现**：`setup(opts)` 在 `init_by_lua_block` 中调用一次，修改配置需重启 Nginx。

**问题**：
- 新增/移除服务需重启 Nginx
- 无法运行时调整 timeout 等参数

**Kong 启发的优化**：

```lua
-- 方案 1：配置文件监听 + 热加载
-- 在 init_worker 阶段启动文件监听
ngx.timer.every(10, function()
    local mtime = get_file_mtime(config_path)
    if mtime ~= last_mtime then
        -- 重新加载配置
        local opts = load_config(config_path)
        require("resty.yar_grpc_bridge").setup(opts)
        last_mtime = mtime
    end
end)

-- 方案 2：ngx.shared.DICT 存储配置（跨 worker 一致）
-- setup() 时写入 shared dict，serve() 时读取
-- 修改配置时更新 shared dict，所有 worker 立即生效
```

**必要性**：低。对于库来说，`init_by_lua_block` 配置是标准做法。热加载更多是运维平台/网关的需求。

**建议优先级**：P3（可选增强）

---

### 9. PDK 抽象层

**Kong 做法**：`kong.request`、`kong.response`、`kong.log` 等 PDK 模块封装 Nginx API，插件不直接调用 `ngx.*`。

**当前实现**：`ngx.*` 调用散落在各模块：

| 模块 | 直接调用的 ngx API |
|------|-------------------|
| `init.lua` | `ngx.req.read_body`, `ngx.req.get_body_data`, `ngx.req.get_body_file`, `ngx.var.uri`, `ngx.exit`, `ngx.HTTP_OK` |
| `errors.lua` | `ngx.header`, `ngx.status`, `ngx.exit`, `ngx.HTTP_OK`, `ngx.print` |
| `grpc2yar.lua` | 无（纯协议转换） |
| `codec.lua` | 无（纯帧编解码） |

**问题**：
- 测试需 mock `ngx` 全局对象
- 未来迁移到非 OpenResty 环境需大量修改

**Kong 启发的优化**：

```lua
-- lib/resty/yar_grpc_bridge/pdk.lua
local _M = {}

_M.request = {
    read_body = function() return ngx.req.get_body_data() end,
    get_path = function() return ngx.var.uri end,
    get_header = function(name) return ngx.var["http_" .. name] end,
}

_M.response = {
    set_header = function(k, v) ngx.header[k] = v end,
    send = function(data) ngx.print(data); ngx.exit(ngx.HTTP_OK) end,
    send_error = function(status) ngx.exit(status) end,
}

_M.log = {
    info = function(msg) ngx.log(ngx.INFO, msg) end,
    warn = function(msg) ngx.log(ngx.WARN, msg) end,
    err = function(msg) ngx.log(ngx.ERR, msg) end,
}

return _M
```

**必要性**：低。当前 `ngx.*` 调用不多（集中在 `init.lua` 和 `errors.lua`），PDK 抽象层会增加一层间接性。但如果落地中间件管线模式，PDK 是配套基础设施。

**建议优先级**：P3（与管线化重构同步考虑）

---

## 三、优化优先级总览

| 优先级 | 优化项 | Kong 模式来源 | 与 OpenSpec 提案关系 |
|--------|--------|--------------|---------------------|
| **P0** | 上下文对象 (ctx) | `kong.ctx.shared` | 结构化日志的基础设施 |
| **P1** | 分阶段生命周期 | Nginx phases | `log_by_lua` 异步日志/指标 |
| **P2** | 中间件管线 | Kong plugin pipeline | 5 项改进落地后重构 |
| **P2** | L1/L2 缓存（熔断器） | `kong.cache` | 熔断器跨 worker 一致性 |
| **P2** | Upstream/Target 负载均衡 | Kong Upstream/Target | 多后端场景 |
| **P3** | 主动健康检查 | Kong active health check | 可选增强 |
| **P3** | 热加载 | Kong declarative config | 运维增强 |
| **P3** | PDK 抽象层 | `kong.pdk` | 与管线化同步 |

---

## 四、与已有 OpenSpec 提案的关系

已有提案 `bridge-observability-resilience` 覆盖了 5 项改进（deadline、日志、body spill、熔断、指标）。本分析补充的 Kong 启发优化与已有提案的关系：

| Kong 启发优化 | 已有提案覆盖？ | 补充说明 |
|---------------|---------------|----------|
| 上下文对象 (ctx) | ❌ 未覆盖 | **新增**：结构化日志落地时需同步引入 ctx |
| 分阶段生命周期 | ❌ 未覆盖 | **新增**：`log_by_lua` 异步日志/指标 |
| 中间件管线 | ❌ 未覆盖 | **后续**：5 项改进落地后重构 |
| L1/L2 缓存 | 部分覆盖（熔断器） | **增强**：熔断器实现时考虑 L2 |
| Upstream/Target | ❌ 未覆盖 | **后续**：多后端场景需要时实现 |

**建议**：
1. 将"上下文对象"和"分阶段生命周期"纳入已有提案的 design.md 更新
2. 中间件管线、负载均衡、热加载作为后续独立提案

---

## 五、总结

Kong 作为业界领先的 OpenResty 网关，其设计模式对我们的协议桥接项目有明确借鉴价值。但需注意**定位差异**：

| 维度 | Kong | 本项目 |
|------|------|--------|
| 定位 | API 网关（平台） | 协议桥接（库） |
| 复杂度 | 插件系统、DB、Admin API | 单一协议转换 |
| 配置 | 动态、声明式 | 静态、Lua table |
| 扩展性 | 插件可插拔 | 源码修改 |

**核心结论**：

1. **立即落地**（P0）：上下文对象 (ctx) — 是结构化日志的基础设施，与已有 OpenSpec 提案协同
2. **短期落地**（P1）：分阶段生命周期 — `log_by_lua` 异步日志/指标对延迟优化至关重要
3. **中期落地**（P2）：中间件管线 — 5 项改进落地后，`serve()` 膨胀时重构
4. **按需落地**（P2-P3）：负载均衡、主动健康检查、热加载、PDK — 取决于业务场景需求

Kong 的"插件化一切"理念对协议桥接库而言过重，但其"分阶段分离"、"上下文流转"、"L1/L2 缓存"三个核心模式可以直接借鉴，显著提升项目的工程化水平。
