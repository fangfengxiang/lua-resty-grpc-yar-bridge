-- lib/resty/yar_grpc_bridge/grpc2yar.lua
-- gRPC → YAR 方向桥接入口层
-- Entry layer for the gRPC → Yar bridge.
--
-- 纯协议转换（pb.decode/extract_params/map_response/pb.encode）已委托核心
-- lua-yar-grpc 的 reverse.decode_request / reverse.encode_response。
-- 入口层只保留：client 创建（persistent 缓存）+ hooks 组装（timing+用户透传）+ 调用编排。
-- 入口本职观测（request ID + 访问日志）在 trace.lua / init.log_phase。

local Yar = require("yar")
local errors = require("yar_grpc.errors")
local core_reverse = require("yar_grpc.reverse")
local grpc_converter = require("yar_grpc.grpc_converter")
local pb_converter = require("yar_grpc.pb_converter")
local host = require("resty.yar_grpc_bridge.host")

---@class yar_grpc_bridge.grpc2yar
local _M = {}

-- 模块级缓存：YAR Client 实例（service name → Client），persistent 模式跨请求复用
local _client_cache = {}

-- 模块级用户 hooks（由 init.lua setup() 通过 set_hooks 透传，对齐 lua-yar opts.hooks）
-- Module-level user hooks (passed through by init.lua setup() via set_hooks, aligned with lua-yar opts.hooks)
local _user_hooks

--- 设置用户 hooks（由 init.lua setup() 调用，透传给 lua-yar client opts.hooks）
-- Set user hooks (called by init.lua setup(), passed through to lua-yar client opts.hooks)
-- 与 lua-yar opts.hooks 对齐：on_request(method, params) / on_response(method, retval, err_obj)
---@param hooks table|nil { on_request:fun, on_response:fun }
function _M.set_hooks(hooks)
    _user_hooks = hooks
end

--- 清空入口层 client 缓存（供 init.setup 重新加载时调用）
-- 协议转换缓存由核心 yar_grpc.clear_cache() 统一管理，入口层不重复清。
function _M.clear_cache()
    _client_cache = {}
end

--- 组装 lua-yar client hooks：内置元数据收集（恒开）+ 用户 hooks 透传
-- Built-in hooks（入口本职，恒开）：收集 yar_call_latency / yar_error_code 到 host.ctx，
-- 供 init.log_phase() 读取输出访问日志。
-- 用户 hooks（可选，通过 set_hooks 注入）：on_request/on_response 透传，pcall 隔离
-- （用户 hooks 是不可控第三方，对标 lua-resty-http pcall ngx.req.socket 模式）。
---@param user_hooks table|nil { on_request:fun, on_response:fun }
---@return table hooks { on_request:fun, on_response:fun }
local function build_hooks(user_hooks)
    local u_req = user_hooks and user_hooks.on_request
    local u_resp = user_hooks and user_hooks.on_response

    return {
        on_request = function(method, params)
            host.ctx.yar_method = method
            host.ctx.yar_call_start = host.now()
            if u_req then
                local ok, err = pcall(u_req, method, params)
                if not ok then
                    host.log(host.LOG_WARN, "[yar_grpc_bridge] on_request hook error: " .. tostring(err))
                end
            end
        end,
        on_response = function(method, retval, err_obj)
            local end_time = host.now()
            host.ctx.yar_call_latency = end_time - (host.ctx.yar_call_start or end_time)
            if err_obj then
                -- Bug 2 防御：err_obj 可能为 string（旧版 lua-yar 或测试 mock）
                local err_code
                if type(err_obj) == "table" then
                    err_code = err_obj.code
                else
                    err_code = "UNKNOWN"
                end
                host.ctx.yar_error_code = err_code or "UNKNOWN"
            else
                host.ctx.yar_error_code = nil
            end
            if u_resp then
                local ok, err = pcall(u_resp, method, retval, err_obj)
                if not ok then
                    host.log(host.LOG_WARN, "[yar_grpc_bridge] on_response hook error: " .. tostring(err))
                end
            end
        end,
    }
end

--- 获取或创建 YAR Client 实例（按 service 名缓存，persistent 模式）
---@param service string gRPC Service 名（用作缓存 key）
---@param service_config table { url=string, options=table|nil }
---@return table|nil client YAR Client 实例
---@return string|nil err 创建失败时的错误信息
local function get_client(service, service_config)
    local cached = _client_cache[service]
    if cached then
        return cached
    end

    local ok_create, client = pcall(Yar.client.new, service_config.url)
    if not ok_create then
        return nil, "failed to create YAR client: " .. tostring(client)
    end

    -- 浅拷贝用户选项（不修改 _svc_cache 中的缓存对象），以便追加 persistent 默认值
    local opts = {}
    if service_config.options then
        for k, v in pairs(service_config.options) do
            opts[k] = v
        end
    end
    if opts.persistent == nil then
        opts.persistent = true
    end

    -- 注入 hooks：内置元数据收集（恒开）+ 用户 hooks 透传（set_hooks 注入）
    -- hooks 签名：on_request(method, params) / on_response(method, retval, err_obj)
    -- hooks 引用 host.ctx（proxy 到 ngx.ctx），per-request 自动隔离，persistent 复用安全
    opts.hooks = build_hooks(_user_hooks)

    local ok_setopt, serr = pcall(client.set_options, client, opts)
    if not ok_setopt then
        return nil, "failed to set YAR client options: " .. tostring(serr)
    end

    _client_cache[service] = client
    return client
end

--- 完整管线：核心 decode_request → client:call → 核心 encode_response
-- 纯协议转换委托核心 yar_grpc.reverse，入口层只做 client 编排 + YAR 调用。
---@param service string gRPC Service 名
---@param method string gRPC Method 名
---@param payload string protobuf 编码的请求 payload
---@param service_config table { url=string, options=table|nil }
---@return string|nil payload protobuf 编码的响应 payload
---@return integer|nil status gRPC 状态码（失败时）
---@return string|nil err 错误信息（失败时）
function _M.handle(service, method, payload, service_config)
    -- 1. 核心解码 gRPC 请求 → yar_method + 位置参数（含 protobuf decode + extract_params）
    local yar_method, params, status, err = core_reverse.decode_request(service, method, payload)
    if not yar_method then
        return nil, status, err
    end

    -- 2. 获取（缓存的）YAR client 并调用（入口层编排职责：persistent + hooks）
    -- client:call() 返回 nil, err（结构化 Error 对象），不抛异常
    -- 无需 pcall 包裹——lua-yar 的 call() 内部已捕获所有错误
    local client, cerr = get_client(service, service_config)
    if not client then
        return nil, errors.INTERNAL, cerr
    end

    local result, call_err = client:call(yar_method, params)
    if call_err then
        local st, msg = errors.map_yar_error(call_err)
        return nil, st, msg
    end

    -- 3. 核心编码 YAR retval → gRPC 响应 payload（含 map_response + protobuf encode）
    local response_payload, enc_err = core_reverse.encode_response(service, method, result)
    if not response_payload then
        return nil, errors.INTERNAL, enc_err
    end

    return response_payload
end

-- 单元测试入口：透传核心 grpc_converter / pb_converter 的纯函数
-- 入口层 converter 已委托核心，这些透传保留原有 bridge.* 测试 API
_M.parse_grpc_path = grpc_converter.parse_grpc_path
_M.method_to_yar = grpc_converter.method_to_yar
_M.extract_params = pb_converter.extract_params
_M.map_response = pb_converter.map_response

return _M
