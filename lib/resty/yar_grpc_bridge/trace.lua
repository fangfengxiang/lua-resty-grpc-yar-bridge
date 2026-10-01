-- lib/resty/yar_grpc_bridge/trace.lua
-- 请求 ID 管理
-- 入口本职观测模块，被 init.lua（serve/log_phase）使用
--
-- 函数：
--   gen_request_id()              — 多熵源混合生成 request ID（内部）
--   get_request_id_from_header()  — 从 HTTP header 提取或生成 ID（内部）
--   get_or_create_request_id()    — 从 host.ctx 读取或创建 ID（内部）
--   get_request_id()              — 公开 API：获取当前请求 ID
--   ensure_request_id()           — 公开 API：确保 ID 存在（serve 阶段调用）

local host = require("resty.yar_grpc_bridge.host")
local string = string

---@class yar_grpc_bridge.trace
local _M = {}

-- 模块级请求 ID 计数器（多熵源之一，per-worker）
-- Module-level request ID counter (one of multi-entropy sources)
local request_seq = 0

--- 生成 request ID（多熵源混合，per-worker 唯一）
-- 熵源：host.time（秒级时间）+ host.worker_pid（进程区分）+ 计数器（进程内单调递增）
-- 对标 lua-yar default_gen_id 设计，但不调用 math.randomseed（库不越权播种）
---@return string request ID（16 进制字符串，便于日志阅读）
local function gen_request_id()
    request_seq = request_seq + 1
    local t = host.time() or 0
    local pid = host.worker_pid() or 0
    local id = (t * 1000000 + pid * 10000 + request_seq) % 0x100000000
    return string.format("%08x", id)
end

--- 从 header 提取或生成请求 ID
-- Extract or generate request ID from HTTP header
---@param header_name? string 请求 ID header 名（默认 "x-request-id"）
---@return string request ID
local function get_request_id_from_header(header_name)
    header_name = header_name or "x-request-id"
    local var_name = "http_" .. header_name:gsub("-", "_")
    local rid = host.var[var_name]
    if rid and rid ~= "" then
        return rid
    end
    return gen_request_id()
end

--- 获取或创建 request ID（从 host.ctx 读取，不存在则生成并注入）
---@return string request ID
local function get_or_create_request_id()
    local ctx = host.ctx
    if ctx.request_id then
        return ctx.request_id
    end
    local id = gen_request_id()
    ctx.request_id = id
    return id
end

--- 获取当前请求的 request ID（公开 API）
-- 供业务代码或日志格式化使用，从 host.ctx 读取或生成
---@return string request ID
function _M.get_request_id()
    return get_or_create_request_id()
end

--- 从 Error 对象提取错误状态字符串（observability/metrics 分类用）
---@param err_obj? table Error 对象（含 code 字段）
---@return string 错误状态（"ok" / "transport" / "timeout" / "protocol" / "not_found" / "exception" / "unknown"）
function _M.error_status(err_obj)
    if not err_obj then
        return "ok"
    end
    -- err_obj 为字符串时（旧版 lua-yar 或测试 mock）降级为 unknown，不崩溃
    if type(err_obj) ~= "table" then
        return "unknown"
    end
    local code = err_obj.code or "unknown"
    return string.lower(code)
end

--- 确保请求 ID 存在（从 header 提取或生成），供 serve() 阶段直接调用
-- 在 YAR hooks 触发前就需要 request ID 的场景使用
---@param header_name? string 请求 ID header 名（默认 "x-request-id"）
---@return string request ID
function _M.ensure_request_id(header_name)
    local ctx = host.ctx
    if not ctx.request_id then
        ctx.request_id = get_request_id_from_header(header_name)
    end
    return ctx.request_id
end

return _M
