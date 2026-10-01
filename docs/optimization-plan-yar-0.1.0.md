# 优化计划：适配 lua-yar 0.1.0 + OpenResty 分阶段加载

> 本计划基于 lua-yar 从 0.0.1 升级到 0.1.0 后的能力变化，重新审视 `lua-resty-yar-grpc-bridge` 的优化空间，并引入 OpenResty 分阶段加载架构。

---

## 一、lua-yar 0.1.0 关键变化

### 1.1 破坏性变更（必须适配）

| 变更 | 影响 | 现有代码位置 |
|------|------|-------------|
| `Client:call()` 返回结构化 `Error` 对象（`{code=, message=}`）替代字符串前缀 | `errors.map_yar_error()` 的 `string.find(err, "transport:")` 全部失效 | `errors.lua:26-42`, `grpc2yar.lua:180-183` |

**旧接口**（字符串前缀）：
```lua
local result, err = client:call("add", {1, 2})
if err then
    -- err 是字符串："transport: connection refused"
    if string.find(err, "transport:", 1, true) then ... end
end
```

**新接口**（结构化 Error 对象）：
```lua
local result, err = client:call("add", {1, 2})
if err then
    -- err 是 table：{ code = "TRANSPORT", message = "connection refused" }
    -- err.code == Yar.Error.TRANSPORT
    -- tostring(err) == "connection refused"
end
```

### 1.2 新增能力（可利用）

| 能力 | API | 解决的问题 |
|------|-----|-----------|
| **Persistent Client** | `transport.persistent = true` | 每请求 `Yar.Client.new()` → 进程级复用，连接跨 call 复用 |
| **Keepalive 池参数** | `transport.keepalive = {pool_size=, idle_timeout=}` | cosocket 连接池参数透传，之前无法配置 |
| **Hooks 钩子** | `set_options({hooks = {on_request=, on_response=}})` | 日志/指标/熔断记录无需改 grpc2yar.lua，注入回调即可 |
| **Log 模块** | `Yar.Log.set_writer(fn)`, `set_level(lvl)` | lua-yar 内部日志可注入 `ngx.log`，统一日志出口 |
| **HTTP Provider 委托** | `Client.set_http_provider(fn)` | 可注入 `lua-resty-http`，替代手动 HTTP 实现 |
| **Error 结构化** | `Yar.Error.TRANSPORT/TIMEOUT/PROTOCOL/NOT_FOUND/EXCEPTION` | 替代字符串前缀匹配，类型安全 |
| **嵌套选项** | `protocol = {}, transport = {}` | 更清晰的选项结构，扁平 key 向后兼容 |

---

## 二、OpenResty 分阶段加载架构

### 2.1 当前架构（两阶段）

```
init_by_lua_block          → setup(opts)    加载 .pb、注入 cosocket
content_by_lua_block       → serve()        全部请求处理逻辑
```

**问题**：
- 日志/指标在 `content_by_lua` 同步执行，增加请求延迟
- 熔断检查、deadline 解析与协议转换混在一起
- 无 `init_worker_by_lua`，无法启动后台定时器（健康检查）
- 无 `log_by_lua`，响应发送后无法异步记录

### 2.2 目标架构（六阶段）

```
init_by_lua_block          → setup()        加载 .pb、注入 cosocket/Log、创建 persistent client
init_worker_by_lua_block  → worker_init()  初始化 shared dict、启动健康检查定时器
rewrite_by_lua_block      → rewrite()       解析 gRPC path、解析 service
access_by_lua_block       → access()        熔断检查、deadline 解析、body 读取、帧解码
content_by_lua_block      → content()       协议转换（protobuf decode → YAR call → protobuf encode）
header_filter_by_lua_block → header_filter() 统一设置 gRPC 响应头
log_by_lua_block          → log_phase()     结构化日志、Prometheus 指标（异步）
```

### 2.3 各阶段职责

#### `init_by_lua`（master 进程，一次）

```lua
function _M.setup(opts)
    -- 1. 加载 .pb 文件（已有）
    -- 2. 解析 services 配置（已有）
    -- 3. 注入 cosocket（已有）
    -- 4. 【新增】注入 Log writer → ngx.log
    Yar.Log.set_writer(function(lvl, msg)
        local ngx_lvl = ({[1]=ngx.DEBUG, [2]=ngx.INFO, [3]=ngx.WARN, [4]=ngx.ERR})[lvl]
        ngx.log(ngx_lvl, "yar: " .. msg)
    end)
    -- 5. 【新增】创建 persistent YAR Client（每服务一个，进程级复用）
    for service_name, svc_config in pairs(services) do
        local client = Yar.Client.new(svc_config.url)
        client:set_options({
            transport = {
                timeout    = svc_config.options and svc_config.options.timeout or 5000,
                persistent = true,
                keepalive  = { pool_size = 64, idle_timeout = 60000 },
            },
        })
        _clients[service_name] = client
    end
end
```

#### `init_worker_by_lua`（每 worker，一次）

```lua
function _M.worker_init()
    -- 1. 初始化 shared dict（熔断器状态跨 worker 共享）
    --    lua_shared_dict grpc_yar_cb 1m;  (nginx.conf)
    -- 2. 启动健康检查定时器（可选）
    if _health_check_enabled then
        ngx.timer.every(5, health_check_loop)
    end
end
```

#### `rewrite_by_lua`（每请求）

```lua
function _M.rewrite()
    -- 解析 gRPC path → {service, method}
    -- 存入 ngx.ctx（请求级上下文，跨阶段共享）
    local path = ngx.var.uri
    local service, method = bridge.parse_grpc_path(path)
    ngx.ctx.service = service
    ngx.ctx.method = method
    ngx.ctx.yar_method = bridge.method_to_yar(method)
    ngx.ctx.start_time = ngx.now()
end
```

#### `access_by_lua`（每请求）

```lua
function _M.access()
    local ctx = ngx.ctx
    -- 1. 查 services（短路：服务不存在直接返回 NOT_FOUND）
    local client = _clients[ctx.service]
    if not client then
        return errors.send_error(errors.NOT_FOUND, "service not found: " .. ctx.service)
    end
    -- 2. 熔断检查（短路：熔断中直接返回 UNAVAILABLE）
    if not circuit_breaker.allow(url) then
        return errors.send_error(errors.UNAVAILABLE, "circuit breaker open")
    end
    -- 3. gRPC deadline 解析
    local grpc_timeout = parse_grpc_timeout(ngx.var.http_grpc_timeout)
    if grpc_timeout and grpc_timeout - 50 <= 0 then
        return errors.send_error(errors.DEADLINE_EXCEEDED, "deadline already exceeded")
    end
    ctx.yar_timeout = grpc_timeout and (grpc_timeout - 50) or nil
    -- 4. 读取请求体 + 解析 gRPC 帧
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then ... end  -- body spill 处理
    local flag, payload = codec.decode_frame(body)
    ctx.payload = payload
    ctx.flag = flag
end
```

#### `content_by_lua`（每请求）

```lua
function _M.content()
    local ctx = ngx.ctx
    -- 纯协议转换：protobuf decode → YAR call → protobuf encode
    local response_payload = bridge.handle(ctx.service, ctx.method, ctx.payload, {
        client = _clients[ctx.service],  -- 复用 persistent client
        timeout = ctx.yar_timeout,        -- deadline 透传
    })
    -- 输出 gRPC 帧
    local frame = codec.encode_frame(response_payload)
    errors.send_ok(frame)
end
```

#### `header_filter_by_lua`（每请求）

```lua
function _M.header_filter()
    -- 统一设置 gRPC 响应头
    ngx.header["content-type"] = "application/grpc"
    -- grpc-status / grpc-message 已在 errors 模块设置
end
```

#### `log_by_lua`（每请求，响应发送后异步）

```lua
function _M.log_phase()
    local ctx = ngx.ctx
    -- 结构化日志（不影响请求延迟）
    local latency = (ngx.now() - (ctx.start_time or 0)) * 1000
    ngx.log(ngx.INFO, string.format(
        "yar_grpc_bridge: rid=%s svc=%s method=%s grpc_status=%s latency=%.2fms",
        ctx.request_id, ctx.service, ctx.method, ctx.grpc_status or 0, latency
    ))
    -- Prometheus 指标记录
    if _metrics then
        _metrics:record(ctx.service, ctx.method, ctx.grpc_status, latency)
    end
end
```

### 2.4 nginx.conf 配置

```nginx
http {
    lua_shared_dict grpc_yar_cb 1m;          # 熔断器跨 worker 状态
    lua_shared_dict grpc_yar_metrics 1m;     # Prometheus 指标（可选）

    init_by_lua_block {
        require("resty.yar_grpc_bridge").setup {
            services = {
                Calculator = {
                    proto = "/app/proto/calc.pb",
                    url   = "http://yar-backend:8888/api",
                    options = { timeout = 5000 },
                },
            },
            yar_options = {
                transport = {
                    persistent = true,
                    keepalive  = { pool_size = 64, idle_timeout = 60000 },
                },
            },
        }
    }

    init_worker_by_lua_block {
        require("resty.yar_grpc_bridge").worker_init()
    }

    server {
        listen 443 ssl http2;

        location / {
            rewrite_by_lua_block      { require("resty.yar_grpc_bridge").rewrite() }
            access_by_lua_block       { require("resty.yar_grpc_bridge").access() }
            content_by_lua_block      { require("resty.yar_grpc_bridge").content() }
            header_filter_by_lua_block { require("resty.yar_grpc_bridge").header_filter() }
            log_by_lua_block          { require("resty.yar_grpc_bridge").log_phase() }
        }

        location /metrics {
            content_by_lua_block { require("resty.yar_grpc_bridge").metrics() }
        }
    }
}
```

---

## 三、具体优化项

### 优化 1：Error 对象适配（P0 — 破坏性变更，必须先做）

**问题**：`errors.map_yar_error()` 使用 `string.find(err, "transport:")` 匹配错误前缀，但 lua-yar 0.1.0 的 `err` 已变为 `{code=, message=}` 结构化对象。

**改动**：

```lua
-- errors.lua 改造
local Yar_Error = require("yar.error")

function _M.map_yar_error(err)
    if not err then
        return _M.INTERNAL, "unknown error"
    end

    -- 兼容：err 可能是 string（旧版）或 table（新版 Error 对象）
    if type(err) == "table" and err.code then
        -- 新版：结构化 Error 对象
        local code_map = {
            [Yar_Error.TRANSPORT] = _M.UNAVAILABLE,
            [Yar_Error.TIMEOUT]   = _M.DEADLINE_EXCEEDED,
            [Yar_Error.PROTOCOL]  = _M.INTERNAL,
            [Yar_Error.NOT_FOUND]  = _M.NOT_FOUND,       -- 新增映射
            [Yar_Error.EXCEPTION]  = _M.INTERNAL,
        }
        local status = code_map[err.code] or _M.INTERNAL
        return status, err.message or tostring(err)
    end

    -- 旧版兼容：字符串前缀（理论上不会走到，但防御性保留）
    local msg = tostring(err)
    if string.find(msg, "transport:", 1, true) then
        return _M.UNAVAILABLE, msg
    elseif string.find(msg, "timeout:", 1, true) then
        return _M.DEADLINE_EXCEEDED, msg
    elseif string.find(msg, "protocol:", 1, true) then
        return _M.INTERNAL, msg
    end
    return _M.INTERNAL, msg
end
```

**影响文件**：`errors.lua`、`grpc2yar.lua`（`tostring(err)` 用于 grpc-message）

---

### 优化 2：Persistent Client 复用（P0 — 性能提升最大）

**问题**：`grpc2yar.lua:166` 每请求 `pcall(Yar.Client.new, url)` 创建新 Client 实例，无连接复用。

**改动**：在 `setup()` 中为每个服务创建 persistent Client，`bridge.handle()` 直接复用。

```lua
-- init.lua setup() 中新增
local _clients = {}  -- service_name → Yar.Client（persistent）

function _M.setup(opts)
    -- ... 已有逻辑 ...

    for service_name, svc_config in pairs(services) do
        local client = Yar.Client.new(svc_config.url)
        -- 合并全局 + per-service 选项
        local merged_opts = merge_options(_yar_options, svc_config.options)
        -- 使用新嵌套选项结构
        client:set_options({
            transport = {
                timeout    = merged_opts.timeout or 5000,
                connect_timeout = merged_opts.connect_timeout or 1000,
                persistent = true,
                keepalive  = {
                    pool_size    = merged_opts.keepalive_pool_size or 64,
                    idle_timeout = merged_opts.keepalive_idle_timeout or 60000,
                },
            },
        })
        _clients[service_name] = client
    end
end
```

```lua
-- grpc2yar.lua handle() 改造
function _M.handle(service, method, payload, service_config)
    -- ... protobuf decode + extract_params ...

    -- 【旧】每请求创建 client
    -- local ok_c, client = pcall(Yar.Client.new, service_config.url)
    -- client:set_options(service_config.options)

    -- 【新】复用 persistent client
    local client = service_config.client
    -- persistent 模式下 client:call() 自动复用连接

    local yar_method = _type_cache[service .. "/" .. method].yar_method
    local ok_call, result, err = pcall(client.call, client, yar_method, params)
    -- ... 后续不变 ...
end
```

**收益**：
- 消除每请求 `Yar.Client.new()` 开销（table 分配 + deep_copy）
- 连接跨 call 复用（persistent 模式缓存 transport 实例）
- cosocket 连接池参数生效（pool_size, idle_timeout）

---

### 优化 3：Hooks 注入可观测性（P1 — 替代 OpenSpec 提案中的手动日志）

**问题**：OpenSpec 提案 `bridge-observability-resilience` 原计划在 `serve()` 中手动添加 `ngx.log`。但 lua-yar 0.1.0 提供了 hooks 机制，可以在 Client 层注入回调。

**改动**：在 `setup()` 创建 Client 时注入 hooks。

```lua
-- init.lua setup() 中创建 client 时
client:set_options({
    transport = { persistent = true, ... },
    hooks = {
        on_request = function(method, params)
            -- 记录请求开始时间
            ngx.ctx.yar_start = ngx.now()
            ngx.ctx.yar_method = method
        end,
        on_response = function(method, retval, err)
            -- 记录 YAR 调用延迟和结果
            local latency = (ngx.now() - (ngx.ctx.yar_start or 0)) * 1000
            ngx.ctx.yar_latency = latency
            if err then
                -- 熔断器记录失败
                circuit_breaker.record_failure(url)
                ngx.ctx.grpc_status = errors.map_yar_error(err)
            else
                -- 熔断器记录成功
                circuit_breaker.record_success(url)
            end
        end,
    },
})
```

**收益**：
- 日志/指标/熔断记录通过 hooks 注入，不修改 `grpc2yar.lua` 核心逻辑
- `on_response` 回调提供 `method, retval, err`，信息完整
- hooks 在 pcall 保护下运行，不影响主流程

**与 OpenSpec 提案的关系**：hooks 可替代提案中 `grpc2yar.lua` 的手动日志改动，但 `log_by_lua` 阶段的异步日志/指标仍需在 bridge 侧实现（hooks 在 `content_by_lua` 中同步执行）。

---

### 优化 4：Log 模块注入（P1 — 统一日志出口）

**改动**：在 `setup()` 中注入 `ngx.log` 为 lua-yar 的 Log writer。

```lua
-- init.lua setup() 中
local Yar = require("yar")

Yar.Log.set_writer(function(lvl, msg)
    local ngx_lvl_map = {
        [Yar.Log.DEBUG] = ngx.DEBUG,
        [Yar.Log.INFO]  = ngx.INFO,
        [Yar.Log.WARN]  = ngx.WARN,
        [Yar.Log.ERROR] = ngx.ERR,
    }
    ngx.log(ngx_lvl_map[lvl] or ngx.INFO, "yar: " .. msg)
end)

-- 生产环境设为 WARN 级别
Yar.Log.set_level(Yar.Log.WARN)
```

**收益**：lua-yar 内部的 `Log.debug("→ " .. method)` 等日志自动走 `ngx.log`，无需修改 lua-yar 源码。

---

### 优化 5：gRPC Deadline 透传（P1 — 利用新选项结构）

**改动**：在 `access_by_lua` 中解析 `grpc-timeout` header，动态设置 Client 的 timeout。

lua-yar 0.1.0 的 `set_options` 支持嵌套结构，可以在运行时动态修改 timeout：

```lua
-- access_by_lua 中
local grpc_timeout = parse_grpc_timeout(ngx.var.http_grpc_timeout)
if grpc_timeout then
    local yar_timeout = grpc_timeout - 50  -- 扣除桥接开销
    if yar_timeout <= 0 then
        return errors.send_error(errors.DEADLINE_EXCEEDED, "deadline exceeded")
    end
    -- 动态设置 per-request timeout（persistent client 的 options 是 per-instance 的）
    -- 注意：persistent 模式下多协程共享 client，需用 ngx.ctx 传递 per-request timeout
    ngx.ctx.yar_timeout = yar_timeout
end

-- bridge.handle 中使用
client:set_options({ transport = { timeout = ctx.yar_timeout } })
-- 或：bridge 层接收 timeout 参数，call 前临时设置
```

**注意**：persistent client 被多协程共享，`set_options` 会修改实例级 options。如果并发请求有不同的 deadline，需要考虑：
- 方案 A：每请求 clone client（失去 persistent 优势）
- 方案 B：bridge 层接收 timeout 参数，call 前临时 setopt，call 后恢复（有竞态）
- 方案 C：lua-yar 支持 `call(method, params, opts)` per-call 选项（需上游支持）
- **推荐方案 D**：persistent client 用默认 timeout，deadline 逻辑在桥接层用 `ngx.timer` + 超时检测实现

---

### 优化 6：HTTP Provider 委托（P2 — 可选增强）

**改动**：可选注入 `lua-resty-http` 替代 lua-yar 手动 HTTP 实现。

```lua
-- init.lua setup() 中（可选）
if opts.http_provider == "resty-http" then
    local provider = require("resty.yar_grpc_bridge.http_provider")
    Yar.Client.set_http_provider(provider)
end
```

```lua
-- lib/resty/yar_grpc_bridge/http_provider.lua（新增，适配 lua-resty-http）
local resty_http = require("resty.http")
return function(url, opts)
    local httpc = resty_http.new()
    local res, err = httpc:request_uri(url, {
        method  = opts.method or "POST",
        body    = opts.body,
        headers = opts.headers,
        timeout = opts.timeout,
    })
    if not res then return nil, err end
    if res.status ~= 200 then return nil, "http status: " .. res.status end
    return res.body
end
```

**收益**：HTTPS over proxy、证书验证、HTTP/2.0 等成熟 HTTP 库能力。

---

### 优化 7：熔断器跨 worker 状态（P2 — 利用 ngx.shared.DICT）

**改动**：熔断器状态存入 `ngx.shared.DICT`，跨 worker 一致。

```lua
-- lua_shared_dict grpc_yar_cb 1m;  (nginx.conf)

local shared = ngx.shared.grpc_yar_cb

local function get_state(url)
    local state = shared:get(url .. ":state")
    local fail  = shared:get(url .. ":fail") or 0
    local open_time = shared:get(url .. ":open_time") or 0
    return state or "CLOSED", fail, open_time
end
```

**收益**：所有 worker 看到一致的熔断状态，避免 worker A 熔断后 worker B 继续发请求。

---

### 优化 8：分阶段架构落地（P1 — OpenResty 最佳实践）

将 `serve()` 拆分为 `rewrite()` / `access()` / `content()` / `header_filter()` / `log_phase()` 五个函数。

**关键收益**：
- `log_by_lua` 在响应发送给客户端**之后**执行 → 日志/指标不增加请求延迟
- `access_by_lua` 可短路（熔断、deadline 过期）→ 避免不必要的 protobuf 解码
- 各阶段职责清晰 → 可测试性提升

**实现策略**：用 `ngx.ctx` 作为跨阶段上下文对象（替代之前 Kong 分析中的自定义 ctx）。

```lua
-- ngx.ctx 天然就是 OpenResty 的请求级上下文
-- 跨阶段共享，请求结束自动回收
ngx.ctx.request_id   = ...
ngx.ctx.service      = ...
ngx.ctx.method       = ...
ngx.ctx.payload      = ...
ngx.ctx.start_time   = ...
ngx.ctx.grpc_status  = ...
```

---

## 四、与已有 OpenSpec 提案的关系

已有提案 `bridge-observability-resilience` 中的 5 项改进，在 lua-yar 0.1.0 下的重新评估：

| 改进项 | 原方案 | lua-yar 0.1.0 后 | 调整 |
|--------|--------|------------------|------|
| gRPC deadline 透传 | `init.lua serve()` 解析 header | `access_by_lua` 解析，`ngx.ctx` 传递 | 阶段调整 |
| 结构化日志 | `serve()` 入口/出口 `ngx.log` | **hooks `on_response` + `log_by_lua`** | hooks 替代手动日志 |
| body spill 预防 | nginx 配置 + `serve()` 中检测 | `access_by_lua` 中检测 | 阶段调整 |
| 熔断器 | `circuit_breaker.lua` + `grpc2yar.lua` 接入 | **hooks `on_response` 记录 + `access_by_lua` 检查** | hooks 简化接入 |
| Prometheus 指标 | `serve()` 出口记录 | **`log_by_lua` 异步记录** | 阶段调整为异步 |

**关键变化**：hooks 机制使得熔断器记录和日志采集可以在 YAR Client 层注入，不需要修改 `grpc2yar.lua`。`log_by_lua` 使得指标记录变为异步。

---

## 五、实现任务清单

### Phase 1：破坏性变更适配（P0，必须先做）

- [ ] **T1.1** `errors.lua`：`map_yar_error()` 适配 `Error` 对象（`err.code` 替代 `string.find`）
- [ ] **T1.2** `grpc2yar.lua`：`handle()` 中 `tostring(err)` 适配（Error 对象有 `__tostring`）
- [ ] **T1.3** `errors.lua`：新增 `NOT_FOUND` 映射（`Yar.Error.NOT_FOUND` → gRPC `NOT_FOUND`）
- [ ] **T1.4** 更新测试 `t/error-scenarios.t`：mock Error 对象替代字符串错误
- [ ] **T1.5** 验证全部测试通过

### Phase 2：Persistent Client + Keepalive（P0）

- [ ] **T2.1** `init.lua`：`setup()` 中为每服务创建 persistent Client
- [ ] **T2.2** `init.lua`：新增 `_clients` 模块级缓存（service_name → Client）
- [ ] **T2.3** `grpc2yar.lua`：`handle()` 改为接收 `client` 参数，复用 persistent Client
- [ ] **T2.4** `init.lua`：`serve()` 中传递 `_clients[service]` 给 `bridge.handle()`
- [ ] **T2.5** 配置选项：`yar_options.transport.persistent`、`keepalive.pool_size`、`idle_timeout`
- [ ] **T2.6** 更新 `docs/api.md`：文档化 persistent 和 keepalive 选项
- [ ] **T2.7** 更新测试：验证 Client 复用和连接池

### Phase 3：Log 模块注入（P1）

- [ ] **T3.1** `init.lua`：`setup()` 中注入 `Yar.Log.set_writer(ngx.log 适配器)`
- [ ] **T3.2** `init.lua`：配置 `Yar.Log.set_level()`（生产 WARN，调试 DEBUG）
- [ ] **T3.3** 更新 `docs/api.md`：文档化 Log 注入

### Phase 4：Hooks 注入可观测性（P1）

- [ ] **T4.1** `init.lua`：创建 Client 时注入 `on_request` / `on_response` hooks
- [ ] **T4.2** hooks `on_response`：记录 YAR 调用延迟、成功/失败到 `ngx.ctx`
- [ ] **T4.3** hooks `on_response`：失败时触发熔断器 `record_failure`
- [ ] **T4.4** 更新测试：验证 hooks 触发

### Phase 5：OpenResty 分阶段架构（P1）

- [ ] **T5.1** `init.lua`：拆分 `serve()` 为 `rewrite()` / `access()` / `content()` / `header_filter()` / `log_phase()`
- [ ] **T5.2** 使用 `ngx.ctx` 作为跨阶段上下文
- [ ] **T5.3** `access()`：熔断检查、deadline 解析、body 读取、帧解码
- [ ] **T5.4** `content()`：纯协议转换
- [ ] **T5.5** `log_phase()`：结构化日志 + 指标（异步）
- [ ] **T5.6** 更新 nginx.conf 示例配置
- [ ] **T5.7** 更新 `docs/api.md`：文档化分阶段 API
- [ ] **T5.8** 更新全部测试适配分阶段架构

### Phase 6：熔断器跨 worker 状态（P2）

- [ ] **T6.1** `circuit_breaker.lua`：使用 `ngx.shared.grpc_yar_cb` 存储状态
- [ ] **T6.2** L1/L2 缓存：worker 级 table (L1) + shared dict (L2)，TTL 1s
- [ ] **T6.3** nginx.conf：`lua_shared_dict grpc_yar_cb 1m;`
- [ ] **T6.4** 更新测试

### Phase 7：HTTP Provider 委托（P2，可选）

- [ ] **T7.1** `http_provider.lua`：lua-resty-http 适配器
- [ ] **T7.2** `init.lua`：`setup()` 中可选注入
- [ ] **T7.3** 更新 `dist.ini`：可选依赖 `lua-resty-http`
- [ ] **T7.4** 更新文档

---

## 六、优先级总览

| 优先级 | Phase | 改进项 | 依赖 |
|--------|-------|--------|------|
| **P0** | Phase 1 | Error 对象适配 | 无（破坏性变更，必须先做） |
| **P0** | Phase 2 | Persistent Client + Keepalive | Phase 1 |
| **P1** | Phase 3 | Log 模块注入 | 无 |
| **P1** | Phase 4 | Hooks 注入可观测性 | Phase 2 |
| **P1** | Phase 5 | 分阶段架构 | Phase 1-4（可渐进式落地） |
| **P2** | Phase 6 | 熔断器跨 worker | Phase 4 |
| **P2** | Phase 7 | HTTP Provider 委托 | 无（可选） |

---

## 七、向后兼容性分析

| 改动 | 向后兼容？ | 说明 |
|------|-----------|------|
| Error 对象适配 | ✅ | `map_yar_error` 同时处理 table 和 string |
| Persistent Client | ✅ | `serve()` API 不变，内部改为复用 |
| Log 注入 | ✅ | 不影响用户代码 |
| Hooks 注入 | ✅ | 不影响用户代码 |
| 分阶段架构 | ⚠️ | `serve()` 拆分为多个函数，nginx.conf 需更新 |
| HTTP Provider | ✅ | 可选，默认不启用 |

**分阶段架构的兼容方案**：保留 `serve()` 作为兼容入口（内部调用各阶段函数），新用户可用分阶段 API。

```lua
-- 兼容模式：serve() 内部调用各阶段
function _M.serve()
    _M.rewrite()
    _M.access()
    _M.content()
    -- header_filter 和 log_phase 由 nginx 配置触发
end
```

---

## 八、总结

lua-yar 0.1.0 的更新精准解决了我们之前识别的多个痛点：

| 之前识别的问题 | lua-yar 0.1.0 解决方案 | 状态 |
|---------------|----------------------|------|
| YAR Client 每请求新建 | `transport.persistent = true` | ✅ 已解决 |
| 连接池参数无法透传 | `transport.keepalive = {pool_size, idle_timeout}` | ✅ 已解决 |
| 无可观测性注入点 | `hooks = {on_request, on_response}` | ✅ 已解决 |
| 日志无统一出口 | `Yar.Log.set_writer(fn)` | ✅ 已解决 |
| 错误分类靠字符串前缀 | `Error.new(code, message)` + `err.code` | ✅ 已解决（破坏性） |
| HTTP 传输手动实现 | `Client.set_http_provider(fn)` | ✅ 已解决 |
| gRPC deadline 透传 | 嵌套选项 `transport.timeout` 可运行时修改 | ⚠️ 需注意并发 |

**OpenResty 分阶段加载**是独立于 lua-yar 的架构优化，核心收益是 `log_by_lua` 异步日志/指标不增加请求延迟。与 lua-yar 的 hooks 机制互补：hooks 在 `content_by_lua` 同步执行（提供 YAR 调用级别的观测），`log_by_lua` 在响应后异步执行（提供请求级别的日志/指标）。
