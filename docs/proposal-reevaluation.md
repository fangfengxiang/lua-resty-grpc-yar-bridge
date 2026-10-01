# 提案重新评测报告

> 基于 lua-yar 0.1.0 最新源码，对 `adapt-yar-v010-phased-loading` 和 `bridge-observability-resilience` 两个未实现提案的重新评测。
> 参考 Kong Gateway 多阶段架构思想，评估本项目的改进空间。

## 1. 执行摘要

两个提案都是在 lua-yar 0.1.0 发布前后设计的，存在以下需要修正的问题：

| 问题 | 严重度 | 说明 |
|------|--------|------|
| Hook 签名与实际不符 | **高** | design.md D3 假设 `on_request(req_info)`，实际是 `on_request(method, params)` |
| 两提案边界模糊 | **高** | `bridge-observability-resilience` 的"不包含"项已被 lua-yar 0.1.0 实现，两提案存在重叠 |
| 5 阶段拆分过度工程 | **中** | Kong 多阶段因插件系统而生，桥接库无插件，`log_by_lua` 是唯一高价值阶段 |
| gRPC deadline 与 persistent Client 冲突 | **中** | persistent 模式下无法 per-request `set_options`，deadline 只能做前后检查 |
| 未利用 lua-yar 0.1.0 新传输选项 | **低** | `connect_timeout`、`ssl_verify`、`proxy`、`resolve`、`max_body_len` 未暴露 |

## 2. `adapt-yar-v010-phased-loading` 重新评测

### 2.1 仍然有效的设计决策

| 决策 | 评价 | 说明 |
|------|------|------|
| D1: Error 双格式兼容 | 保持 | 代码映射表正确，`Error.TRANSPORT/TIMEOUT/PROTOCOL/NOT_FOUND/EXCEPTION` 与源码一致 |
| D2: Persistent Client | 保持 | `client.lua:204-214` 确认 persistent 模式缓存 `_transport`，失败自动清 nil 重建 |
| D4: Log 注入 | 保持 | `log.lua` 的 `set_writer(fn)` / `set_level(lvl)` 接口与设计一致 |
| D6: HTTP Provider 委托 | 降级 | lua-yar 0.1.0 的 `manual_request` 已支持 HTTPS/proxy/chunked，HTTP Provider 价值降低 |

### 2.2 需要修正的设计决策

#### D3: Hooks 签名错误 — 必须修正

**design.md 原文：**
> `on_request(req_info)`：记录 `ngx.ctx.yar_call_start = ngx.now()`
> `on_response(resp_info)`：计算延迟 `ngx.ctx.yar_call_latency`...

**lua-yar 0.1.0 实际签名（`client.lua:202, 234, 243, 248, 259, 262`）：**
```lua
run_hook(hooks and hooks.on_request, method, params)
run_hook(hooks and hooks.on_response, method, retval_or_nil, err_obj_or_nil)
```

**修正方案：**
```lua
local function on_request_cb(method, params)
    ngx.ctx.yar_call_start = ngx.now()
    ngx.ctx.yar_method = method
end

local function on_response_cb(method, retval, err_obj)
    ngx.ctx.yar_call_end = ngx.now()
    ngx.ctx.yar_call_latency = ngx.ctx.yar_call_end - (ngx.ctx.yar_call_start or ngx.ctx.yar_call_end)
    if err_obj then
        ngx.ctx.yar_call_status = err_obj.code  -- "TRANSPORT"/"TIMEOUT"/...
    else
        ngx.ctx.yar_call_status = "OK"
    end
end
```

**关键差异：** hooks 不接收请求/响应结构体，只接收 `(method, params)` 和 `(method, retval, err_obj)`。延迟需通过 `ngx.ctx` 跨回调传递。

#### D5: 5 阶段拆分 → 简化为 2 阶段 — 建议修正

**Kong 多阶段架构分析：**

Kong 使用全部 Nginx 阶段是因为它有**插件系统**——不同插件在不同阶段执行（认证插件在 access，日志插件在 log，改写插件在 rewrite）。桥接库**没有插件**，5 阶段拆分将带来：

| 阶段 | 提案中的职责 | Kong 对应 | 桥接库是否需要独立阶段 |
|------|-------------|-----------|---------------------|
| rewrite | 解析 gRPC path | URL 改写、认证前置 | 否，1 行 `ngx.var.uri:match()` 无需独立 |
| access | 服务查找、熔断检查 | 认证、ACL、限流 | 否，查表 + 1 个 if 判断 |
| content | protobuf/YAR/encode | 桥接转发 | 是，核心逻辑 |
| header_filter | 设置 content-type | 改写响应头 | 否，当前 `send_ok()`/`send_error()` 已内联处理 |
| log | 异步日志/指标 | 日志插件 | 是，**唯一高价值阶段** |

**建议方案：** 保留 `serve()` 在 `content_by_lua`，新增 `log_phase()` 在 `log_by_lua`：

```nginx
location / {
    content_by_lua_block { require("resty.yar_grpc_bridge").serve() }
    log_by_lua_block     { require("resty.yar_grpc_bridge").log_phase() }
}
```

**理由：**
- `serve()` 内部重构使用 `ngx.ctx` 存储元数据（service、method、status、latency），不改变外部 API
- `log_phase()` 从 `ngx.ctx` 读取元数据，异步执行日志/指标
- 用户只需在 nginx 配置中加一行 `log_by_lua_block`，迁移成本最低
- 避免 5 个阶段函数的维护复杂度和文档负担

#### D7: gRPC deadline 与 persistent Client 冲突 — 需要重新设计

**冲突点：** `bridge-observability-resilience` 提案说"扣除 50ms 桥接开销后设为 YAR Client timeout"，但 persistent Client 不支持 per-request `set_options`。

**lua-yar 0.1.0 `call()` 的超时来源（`client.lua:184`, `tcp.lua:67`）：**
```lua
local trans = self.options.transport
-- tcp.lua:
local timeout = self.transport_opts.timeout or 5000
```

`call()` 从 `self.options.transport.timeout` 读取超时，这是 setup 时设置的固定值。

**修正方案：** gRPC deadline 分两层处理：
1. **前置检查（serve 入口）**：解析 `grpc-timeout`，若已过期 → 直接返回 `DEADLINE_EXCEEDED`
2. **后置检查（YAR 调用返回后）**：若 YAR 调用耗时超过 deadline → 返回 `DEADLINE_EXCEEDED`
3. **不修改 Client 超时**：Client 使用 setup 时配置的固定超时作为上限

### 2.3 新发现的利用点

lua-yar 0.1.0 的 `DEFAULT_OPTIONS.transport` 暴露了多个新选项，提案未覆盖：

| 选项 | 源码位置 | 桥接层价值 |
|------|---------|-----------|
| `connect_timeout` | `client.lua:40` | 分离连接超时和读写超时，连接慢的后端可独立配置 |
| `ssl_verify` | `client.lua:47` | HTTPS 后端证书验证控制（自签证书场景） |
| `proxy` | `client.lua:43` | 通过 HTTP 代理访问 YAR Server |
| `resolve` | `client.lua:44` | 自定义 DNS 解析（绕过系统 DNS） |
| `max_body_len` | `client.lua:45` | 请求体大小限制（安全防护） |

**建议：** 在 `yar_options.transport` 中透传这些选项，无需额外代码——lua-yar 的 `deep_merge` 会自动处理。

## 3. `bridge-observability-resilience` 重新评测

### 3.1 提案前提已变化

提案"不包含"部分原文：
> - YAR Client 实例复用 / 连接池参数透传 → 需 lua-yar 上游支持
> - 限流 / 背压 → 需 lua-yar 上游钩子机制

**lua-yar 0.1.0 已全部实现：**
- Client 复用：`transport.persistent = true` + `_transport` 缓存
- 连接池参数：`transport.keepalive = {pool_size=, idle_timeout=}`
- 钩子机制：`hooks = {on_request=, on_response=}`

**影响：** 提案边界需要重新定义。`adapt-yar-v010-phased-loading` 已覆盖 Client 复用和 hooks 注入，`bridge-observability-resilience` 应聚焦于**利用**这些能力实现可观测性和韧性。

### 3.2 各改进项重新评估

| # | 改进项 | 原优先级 | 重新评估 | 说明 |
|---|--------|---------|---------|------|
| 1 | gRPC deadline | P0 | 修正 | 不能 per-request 设 Client timeout，改为前后检查方案 |
| 2 | 结构化日志 | P0 | 保持 | `log_by_lua` + hooks 数据是正确路径 |
| 3 | Body spill 预防 | P1 | 保持 | 简单有效 |
| 4 | 熔断器 | P1 | 增强 | hooks 的 `on_response` 可直接记录失败，无需修改 grpc2yar.lua |
| 5 | Prometheus 指标 | P2 | 保持 | `log_by_lua` 是正确位置 |

### 3.3 熔断器与 hooks 的协同

**原提案方案：** 在 `grpc2yar.lua handle()` 中接入熔断器，调用前后检查/记录。

**lua-yar 0.1.0 hooks 方案（更优）：**

```lua
-- setup() 中创建 Client 时注入 hooks
local url = svc_config.url
local cb = circuit_breaker  -- 模块引用

local on_response = function(method, retval, err_obj)
    if err_obj then
        -- 仅传输层错误触发熔断，协议错误不触发
        if err_obj.code == Yar_Error.TRANSPORT or err_obj.code == Yar_Error.TIMEOUT then
            cb.record_failure(url, err_obj.code)
        end
    else
        cb.record_success(url)
    end
end

-- serve()/content() 中 YAR 调用前检查
if not cb.allow(url) then
    errors.send_error(errors.UNAVAILABLE, "circuit breaker open: " .. url)
    return
end
```

**优势：**
- 熔断器记录在 hooks 回调中，不侵入 `grpc2yar.lua`
- hooks 的 pcall 保护确保熔断器异常不影响主流程
- `on_response` 的 `err_obj.code` 提供结构化错误分类，比字符串匹配更可靠

### 3.4 gRPC deadline 修正方案

```lua
-- serve() 入口解析 deadline
local function parse_grpc_timeout()
    local h = ngx.var.http_grpc_timeout  -- grpc-timeout header
    if not h then return nil end
    local value, unit = h:match("^(%d+)([HMSmun])$")
    if not value then return nil end
    local multipliers = {H=3600, M=60, S=1, m=0.001, u=0.000001, n=0.000000001}
    return tonumber(value) * (multipliers[unit] or 1) * 1000  -- -> ms
end

-- 在 serve() 中
local deadline_ms = parse_grpc_timeout()
ngx.ctx.grpc_deadline_ms = deadline_ms
ngx.ctx.request_start = ngx.now()

-- 前置检查
if deadline_ms and (ngx.now() - ngx.ctx.request_start) * 1000 >= deadline_ms then
    errors.send_error(errors.DEADLINE_EXCEEDED, "deadline already exceeded")
    return
end

-- ... YAR 调用 ...

-- 后置检查
local elapsed_ms = (ngx.now() - ngx.ctx.request_start) * 1000
if deadline_ms and elapsed_ms >= deadline_ms then
    errors.send_error(errors.DEADLINE_EXCEEDED, "deadline exceeded after call")
    return
end
```

## 4. Kong 多阶段架构对本项目的启示

### 4.1 适用 vs 不适用

| Kong 模式 | 适用性 | 理由 |
|-----------|--------|------|
| **log_by_lua 异步** | 高价值 | 请求级日志/指标异步化，不增加响应延迟 |
| **ngx.ctx 上下文流** | 高价值 | 跨阶段数据传递，替代局部变量 |
| **阶段分离** | 部分适用 | 桥接库无插件，content + log 两阶段足够 |
| **插件优先级** | 不适用 | 无插件系统 |
| **PDK 模式** | 不适用 | 库模式无插件 API |
| **Upstream/Target LB** | 不适用 | 当前每 service 单 URL，无负载均衡需求 |
| **主动健康检查** | 不适用 | 熔断器（被动检查）已足够 |
| **L1/L2 缓存** | 后续考虑 | L1 模块级 table 已有，L2 `ngx.shared.DICT` 为后续独立 change |

### 4.2 Kong 的核心教训

Kong 的复杂度来自于它是**网关**（多租户、多路由、多插件）。本项目是**桥接库**（单路由、无插件、嵌入用户 nginx）。Kong 的"插件化一切"对本项目是反模式。但 Kong 的"**将副作用推到 log 阶段**"是直接可用的。

## 5. 新发现的改进机会

### 5.1 lua-yar 0.1.0 传输选项透传

```lua
-- setup() 中透传新选项
client:set_options({
    transport = {
        timeout         = merged_opts.timeout or 5000,
        connect_timeout = merged_opts.connect_timeout or 1000,
        persistent      = true,
        keepalive        = { pool_size = 64, idle_timeout = 60000 },
        ssl_verify       = merged_opts.ssl_verify ~= false,  -- 默认 true
        proxy            = merged_opts.proxy or "",
        resolve          = merged_opts.resolve or "",
        max_body_len     = merged_opts.max_body_len,
    },
})
```

### 5.2 LuaLS 类型注解

lua-yar 正在添加 `---@class` / `---@param` / `---@return` 注解。本项目应跟进，提升 IDE 体验。

### 5.3 OpenResty 端到端测试

lua-yar 的 `openresty-integration-test` 提案指出 cosocket 注入、连接池参数透传等关键路径零验证。本项目同样需要 OpenResty 环境的 e2e 测试。

## 6. 推荐行动计划

### 6.1 合并两提案为一个

两提案边界已模糊，建议合并为单一 change `adapt-yar-v010-production-ready`：

```
adapt-yar-v010-phased-loading（已有）
  + bridge-observability-resilience（已有）
  = adapt-yar-v010-production-ready（合并）
```

### 6.2 修正后的优先级

| 优先级 | 改进项 | 来源提案 | 修正点 |
|--------|--------|---------|--------|
| P0 | Error 适配（table + string 双格式） | adapt-yar | 无修正 |
| P0 | Persistent Client + 传输选项透传 | adapt-yar | 新增 `connect_timeout`/`ssl_verify`/`proxy`/`resolve`/`max_body_len` |
| P0 | Log 注入 | adapt-yar | 无修正 |
| P0 | Hooks 注入（修正签名） | adapt-yar | `on_request(method, params)` / `on_response(method, retval, err_obj)` |
| P0 | `log_phase()` + `ngx.ctx` | adapt-yar | 简化为 2 阶段（content + log），不做 5 阶段拆分 |
| P0 | gRPC deadline 前后检查 | observability | 不修改 Client timeout，改为前后检查 |
| P0 | 结构化日志 | observability | `log_by_lua` 异步，hooks 数据写入 `ngx.ctx` |
| P1 | Body spill 预防 | observability | 无修正 |
| P1 | 熔断器（hooks 驱动） | observability | 利用 `on_response` hook 记录失败，不侵入 grpc2yar.lua |
| P2 | Prometheus 指标 | observability | `log_by_lua` 中记录 |
| P3 | HTTP Provider 委托 | adapt-yar | 降级优先级，lua-yar manual_request 已足够 |
| P3 | LuaLS 类型注解 | 新增 | 跟进 lua-yar |
| P3 | OpenResty e2e 测试 | 新增 | 跟进 lua-yar |

### 6.3 架构简化对比

```
原提案架构（5 阶段）:
  init_by_lua      -> setup()
  rewrite_by_lua   -> rewrite()
  access_by_lua    -> access()
  content_by_lua   -> content()
  header_filter_by_lua -> header_filter()
  log_by_lua       -> log_phase()

修正后架构（2 阶段 + 1 可选）:
  init_by_lua      -> setup()          (不变)
  content_by_lua   -> serve()          (内部用 ngx.ctx 存元数据)
  log_by_lua       -> log_phase()      (新增，异步日志/指标)
```

**用户迁移成本：** 仅需在 nginx 配置中加一行 `log_by_lua_block`。

### 6.4 实现顺序建议

```
Phase 1 (P0): 基础适配
  1. Error 适配 (errors.lua)
  2. Persistent Client + 传输选项透传 (init.lua setup)
  3. Log 注入 (init.lua setup)
  4. Hooks 注入 (init.lua setup, 修正签名)
  5. Bridge 适配 (grpc2yar.lua handle 接收 client 参数)

Phase 2 (P0): 可观测性
  6. ngx.ctx 元数据存储 (serve() 内部重构)
  7. log_phase() 函数 (新增)
  8. 结构化日志 (log_phase 中实现)
  9. gRPC deadline 前后检查 (serve 中实现)

Phase 3 (P1): 韧性
  10. 熔断器模块 (circuit_breaker.lua 新增)
  11. 熔断器 hooks 集成 (on_response 中记录)
  12. Body spill 预防 (nginx 配置 + WARN 日志)

Phase 4 (P2-P3): 增强
  13. Prometheus 指标 (log_phase 中实现)
  14. HTTP Provider 委托 (http_provider.lua 新增)
  15. LuaLS 类型注解
  16. OpenResty e2e 测试
```
