-- lib/resty/yar_grpc_bridge/init.lua
-- lua-resty-yar-grpc-bridge: gRPC → YAR 协议代理 OPM 包入口
--
-- 在 init_by_lua_block 阶段调用 setup(opts) 一次，完成：
--   1. 加载预编译 .pb 二进制描述符（pb.load）
--   2. 存储 services（服务名 → { proto, url, options }）
--   3. 注入 cosocket（Yar.client.set_socket(ngx.socket)）
--   4. 配置 YAR 默认选项
--
-- 在 content_by_lua_block 阶段调用 serve()，处理单个 gRPC 请求：
--   读取请求体 → 解析 gRPC 帧 → 解析 path → 查 services → bridge.handle → 输出响应

local ngx = ngx
local pb = require("pb")
local Yar = require("yar")
local bridge = require("resty.yar_grpc_bridge.grpc2yar")
local trace = require("resty.yar_grpc_bridge.trace")
local host = require("resty.yar_grpc_bridge.host")
-- 核心协议转换库 lua-yar-grpc（纯函数，运行时无关）
-- Core protocol conversion library lua-yar-grpc (pure functions, runtime-agnostic)
local codec = require("yar_grpc.codec")
local errors = require("yar_grpc.errors")
local grpc_converter = require("yar_grpc.grpc_converter")
local core_deadline = require("yar_grpc.deadline")
local core = require("yar_grpc")

---@class yar_grpc_bridge
---@field VERSION string
local _M = {}
_M.VERSION = "0.1.0"

-- 模块级状态
-- Module-level state
local _services = {} -- 服务名 → { url=, options= }
local _yar_options = {}
local _svc_cache = {} -- 解析后的服务配置缓存（service name → {url, options}）
-- 默认请求体上限：8MB，对齐 lua-yar Framing.DEFAULT_MAX_BODY_LEN
-- Default request body size limit: 8MB, aligned with lua-yar Framing.DEFAULT_MAX_BODY_LEN
local DEFAULT_MAX_PAYLOAD_BYTES = 8388608
local _max_payload_bytes = DEFAULT_MAX_PAYLOAD_BYTES

-- lua-yar Log 级别 → host 日志常量映射
-- lua-yar 有 DEBUG(1)/INFO(2)/WARN(3)/ERROR(4)，nginx 无 DEBUG 级别，映射到 INFO
local _LOG_LEVEL_MAP = {
    [Yar.log.DEBUG] = host.LOG_INFO,
    [Yar.log.INFO] = host.LOG_INFO,
    [Yar.log.WARN] = host.LOG_WARN,
    [Yar.log.ERROR] = host.LOG_ERR,
}
_M._LOG_LEVEL_MAP = _LOG_LEVEL_MAP

--- 递归合并：table key 递归合并，非 table key 直接覆盖
-- 对齐 lua-yar client.lua 的 deep_merge 语义（含 depth > 100 防护）
---@param target table 目标 table（原地修改）
---@param source table 源 table
---@param depth? number 当前递归深度（内部使用）
---@return table 合并后的 target
local function deep_merge(target, source, depth)
    depth = depth or 0
    if depth > 100 then
        return target
    end
    for k, v in pairs(source) do
        if type(v) == "table" and type(target[k]) == "table" then
            deep_merge(target[k], v, depth + 1)
        else
            target[k] = v
        end
    end
    return target
end

--- 加载 .pb 二进制描述符文件
---@param file string 文件路径
---@return boolean 成功
---@return string|nil err 错误信息
local function load_pb_file(file)
    local f, err = io.open(file, "rb")
    if not f then
        return false, "cannot open proto file: " .. file .. " (" .. (err or "unknown") .. ")"
    end
    local data = f:read("*a")
    f:close()

    if not data or #data == 0 then
        return false, "empty proto file: " .. file
    end

    local ok, res, offset = pcall(pb.load, data)
    if not ok then
        return false, "failed to load " .. file .. ": " .. tostring(res)
    end
    -- lua-protobuf 对格式错误的 descriptor 走返回值失败协议（false, offset），不抛异常
    -- pcall 恒 ok，必须检查第二返回值（Bug 1 修复）
    if res == false then
        return false, "invalid .pb descriptor " .. file .. " (parse error at offset " .. tostring(offset) .. ")"
    end
    return true
end

-- HTTP 响应函数（Category 2：与 HTTP 框架绑定，从 errors.lua 移入入口层）
-- HTTP response functions (Category 2: HTTP framework bound, moved from errors.lua to entry layer)

--- 发送 gRPC 错误响应
-- trailers-only 响应（无 body）：grpc-status 放在 HEADERS frame 中
-- grpc-status/grpc-message 通过 nginx add_trailer + $grpc_status 变量发送
-- 统一写 host.ctx.grpc_status，调用方无需再手动赋值（收口）
---@param status integer gRPC 状态码
---@param message? string grpc-message
local function send_error(status, message)
    host.ctx.grpc_status = status
    -- 错误响应无 body：grpc-status 直接写 leading response header（符合 gRPC 规范——
    -- 错误响应的 grpc-status 在 HEADERS frame 带 END_STREAM）。
    -- 同时设 ngx.var 供 nginx add_trailer 指令兼容（若部署用 HTTP/2 trailer 方式）。
    -- 注：ngx.location.capture 子请求的 res.header 不含 add_header 指令的 header，
    -- 必须用 ngx.header 直接设才能被 capture 读取（测试依赖此路径）。
    ngx.header["grpc-status"] = tostring(status)
    ngx.header["grpc-message"] = message or ""
    ngx.var.grpc_status = tostring(status)
    ngx.var.grpc_message = message or ""
    ngx.header["content-type"] = "application/grpc"
    ngx.status = ngx.HTTP_OK
    return ngx.exit(ngx.HTTP_OK)
end

--- 发送 gRPC 成功响应
-- gRPC 成功响应布局：Headers(content-type, grpc-status=0) → DATA(gRPC frame) → Trailers(grpc-status=0)
-- grpc-status 规范上在 trailers，但 ngx.location.capture 子请求的 res.header 不含 add_header/
-- add_trailer 指令的 header（OpenResty 限制）。为让 capture 测试能读取 grpc-status，
-- 此处同时用 ngx.header 设 leading header；生产 HTTP/2 的 trailer 由 nginx add_trailer 指令 +
-- ngx.var.grpc_status 输出（部署时配置）。统一写 host.ctx.grpc_status = 0（收口）。
---@param frame string 完整的 gRPC 帧（已由 codec.encode_frame 编码）
local function send_ok(frame)
    host.ctx.grpc_status = errors.OK
    ngx.header["grpc-status"] = "0"
    ngx.header["grpc-message"] = ""
    ngx.var.grpc_status = "0"
    ngx.var.grpc_message = ""
    ngx.header["content-type"] = "application/grpc"
    ngx.status = ngx.HTTP_OK
    ngx.print(frame)
    return ngx.exit(ngx.HTTP_OK)
end

--- 初始化：加载 .pb 文件、配置 services、注入 cosocket
-- 在 init_by_lua_block 中调用一次
--
-- 示例配置：
--   services  = {                                  -- 服务配置（proto + endpoint 合一）
--       Calculator = {
--           proto   = "proto/calc.pb",              -- .pb 文件路径
--           url     = "http://127.0.0.1:8888/api",  -- YAR Server URL
--           options = { timeout = 5000 },           -- 可选，per-service 覆盖
--       },
--       UserService = { proto = "...", url = "..." },
--   }
--   yar_options  = { timeout = 3000, ... }  -- YAR client 全局默认选项
---@param opts table { services:table, yar_options:table }
---@return table self
function _M.setup(opts)
    opts = opts or {}

    -- 0. 清空缓存（支持重复初始化：测试、热加载）
    -- 核心协议转换缓存（类型名/字段索引）+ 入口层 client 缓存
    core.clear_cache()
    bridge.clear_cache()
    _svc_cache = {}

    -- 1. 解析 services：加载 .pb 文件 + 存储 endpoint 配置
    local services = opts.services
    if type(services) ~= "table" or next(services) == nil then
        error("yar_grpc_bridge: services is required and must be a non-empty table", 0)
    end

    local loaded_files = {} -- 去重：同一 .pb 文件只加载一次

    _services = {}
    for service_name, svc_config in pairs(services) do
        if type(svc_config) ~= "table" then
            error("yar_grpc_bridge: service config for '" .. service_name .. "' must be a table", 0)
        end

        -- 加载 .pb 文件（去重）
        local proto_file = svc_config.proto
        if not proto_file or type(proto_file) ~= "string" then
            error("yar_grpc_bridge: service '" .. service_name .. "' is missing or has invalid 'proto' field", 0)
        end
        if not loaded_files[proto_file] then
            local ok, err = load_pb_file(proto_file)
            if not ok then
                error("yar_grpc_bridge: " .. err, 0)
            end
            loaded_files[proto_file] = true
        end

        -- 校验 url
        local url = svc_config.url
        if not url or type(url) ~= "string" then
            error("yar_grpc_bridge: service '" .. service_name .. "' is missing or has invalid 'url' field", 0)
        end

        -- 校验 options（可选，但若提供则必须为 table）
        local svc_opts = svc_config.options
        if svc_opts ~= nil and type(svc_opts) ~= "table" then
            error("yar_grpc_bridge: service '" .. service_name .. "' options must be a table", 0)
        end

        _services[service_name] = {
            url = url,
            options = svc_opts,
        }
    end

    -- 1a. 检测多个 service 指向同一 url（潜在 method 撞名风险）
    -- PHP Yar_Server 只注册一个对象实例，若多个 service 共用同一 url，
    -- 且 PHP 端只注册一个类，不同 service 的同名 method 会落到同一类方法。
    -- 此为部署告警，不阻断初始化（合法的聚合类场景仍允许）。
    local url_services = {}
    for service_name, svc in pairs(_services) do
        local url = svc.url
        if not url_services[url] then
            url_services[url] = {}
        end
        url_services[url][#url_services[url] + 1] = service_name
    end
    for url, names in pairs(url_services) do
        if #names > 1 then
            host.log(
                host.LOG_WARN,
                "yar_grpc_bridge: multiple services share the same url '"
                    .. url
                    .. "': "
                    .. table.concat(names, ", ")
                    .. " — ensure each service maps to a distinct PHP class "
                    .. "to avoid method-name collisions"
            )
        end
    end

    -- 2. 存储 YAR 默认选项
    _yar_options = opts.yar_options or {}

    -- 2a. 请求体大小上限（P0-4，DoS 防护）
    if opts.max_payload_bytes ~= nil then
        if type(opts.max_payload_bytes) ~= "number" or opts.max_payload_bytes <= 0 then
            error("yar_grpc_bridge: max_payload_bytes must be a positive integer", 0)
        end
        _max_payload_bytes = opts.max_payload_bytes
    else
        _max_payload_bytes = DEFAULT_MAX_PAYLOAD_BYTES
    end

    -- 2b. 用户 hooks 透传（对齐 lua-yar opts.hooks，可选）
    bridge.set_hooks(opts.hooks)

    -- 3. 注入 cosocket（出向 YAR 调用走 OpenResty 非阻塞 I/O）
    Yar.client.set_socket(ngx.socket)

    -- 4. 注入 Log writer：将 lua-yar 内部日志路由到 host.log
    Yar.log.set_writer(function(lvl, msg)
        host.log(_LOG_LEVEL_MAP[lvl] or host.LOG_ERR, "yar: " .. msg)
    end)

    -- 5. 设置日志级别（默认 WARN，与 lua-yar 自身默认一致）
    Yar.log.set_level(opts.log_level or Yar.log.WARN)

    return _M
end

--- 解析服务配置为最终 YAR 调用参数（合并全局默认 + per-service 覆盖）
---@param service_name string 服务名（用作缓存 key）
---@return string|nil url YAR Server URL
---@return table|nil opts 合并后的 YAR 选项
local function resolve_service_config(service_name)
    -- 从缓存获取已解析的配置
    local cached = _svc_cache[service_name]
    if cached then
        return cached.url, cached.options
    end

    local svc = _services[service_name]
    if not svc then
        return nil, nil
    end

    -- 合并全局默认 + per-service 覆盖（deep_merge 正确处理嵌套子组如 keepalive）
    local opts = {}
    deep_merge(opts, _yar_options)
    if svc.options then
        deep_merge(opts, svc.options)
    end

    _svc_cache[service_name] = { url = svc.url, options = opts }
    return svc.url, opts
end

--- 处理单个 gRPC 请求（在 content_by_lua_block 中调用）
-- 读取请求体 → 解析 gRPC 帧 → 检测流式 → 解析 path → 查 services → bridge.handle → 输出响应
---@return nil
function _M.serve() --luacheck: no unused args
    -- 0. 记录请求开始时间，解析 deadline
    local request_start = host.now()
    local deadline_ms = core_deadline.parse_timeout(host.var.http_grpc_timeout)
    host.ctx.request_start = request_start
    host.ctx.grpc_deadline_ms = deadline_ms

    -- 0a. 生成/提取请求 ID（委托给 trace 模块，消除内联重复）
    trace.ensure_request_id("x-request-id")

    -- 0b. 前置 deadline 检查（核心 check_expired 接受注入的 now，运行时无关）
    if core_deadline.check_expired(deadline_ms, request_start, host.now()) then
        send_error(errors.DEADLINE_EXCEEDED, "deadline already exceeded")
        return
    end

    -- 1. Content-Length 预检（P0-4，DoS 防护：超限不产生读 I/O）
    local content_length = tonumber(host.var.http_content_length)
    if content_length and content_length > _max_payload_bytes then
        send_error(errors.RESOURCE_EXHAUSTED, "request body too large")
        return
    end

    -- 2. 读取请求体
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        -- 请求体可能被写入临时文件（body spill）
        local file = ngx.req.get_body_file()
        if file then
            host.log(host.LOG_WARN, "request body spilled to disk: " .. file)
            -- 先查文件大小，超限不读入内存（P0-4 兜底防线）
            local f = io.open(file, "rb")
            if f then
                f:seek("end")
                local fsize = f:seek("cur")
                f:seek("set")
                if fsize > _max_payload_bytes then
                    f:close()
                    send_error(errors.RESOURCE_EXHAUSTED, "request body too large")
                    return
                end
                body = f:read("*a")
                f:close()
            end
        end
    end

    -- 2b. 内存 body 超限检查（file spill 路径已在上面检查 fsize；
    --     Content-Length 预检对子请求/缺 header 的请求无效，此处为兜底防线）
    if body and #body > _max_payload_bytes then
        send_error(errors.RESOURCE_EXHAUSTED, "request body too large")
        return
    end

    -- 3. 解析 gRPC 帧
    local flag, payload, frame_size, err = codec.decode_frame(body)
    if not flag then
        send_error(errors.INVALID_ARGUMENT, err)
        return
    end

    -- 4. 压缩标志检查
    if flag ~= codec.COMPRESSION_NONE then
        send_error(errors.UNIMPLEMENTED, "compression not supported")
        return
    end

    -- 5. 流式模式检测（多帧 = streaming）
    if codec.has_multiple_frames(body, frame_size) then
        send_error(errors.UNIMPLEMENTED, "streaming mode not supported")
        return
    end

    -- 6. 解析 gRPC path
    local path = host.var.uri
    local service, method, perr = grpc_converter.parse_grpc_path(path)
    if not service then
        send_error(errors.INVALID_ARGUMENT, perr)
        return
    end

    -- 写入请求元数据到 host.ctx（供 log_by_lua 阶段读取）
    host.ctx.grpc_service = service
    host.ctx.grpc_method = method

    -- 7. 查 services
    local url, svc_opts = resolve_service_config(service)
    if not url then
        send_error(errors.NOT_FOUND, "service not found: " .. service)
        return
    end

    -- 8. 调用 bridge.handle（完整管线，pcall 防止未预期异常逃逸）
    local ok, response_payload, status, errmsg = pcall(bridge.handle, service, method, payload, {
        url = url,
        options = svc_opts,
    })
    if not ok then
        send_error(errors.INTERNAL, "uncaught error: " .. tostring(response_payload))
        return
    end

    if not response_payload then
        send_error(status or errors.INTERNAL, errmsg)
        return
    end

    -- 8a. 后置 deadline 检查（核心 check_expired，now 注入）
    if core_deadline.check_expired(deadline_ms, request_start, host.now()) then
        send_error(errors.DEADLINE_EXCEEDED, "deadline exceeded after call")
        return
    end

    -- 9. 输出成功响应
    local frame = codec.encode_frame(response_payload)
    send_ok(frame)
end

--- 异步日志阶段（在 log_by_lua_block 中调用）
-- 从 host.ctx 读取请求元数据和 YAR 调用元数据，输出结构化访问日志行
-- 所有字段做 nil 兜底，确保 serve() 未执行时不报错
---@return nil
function _M.log_phase()
    local ctx = host.ctx
    local service = ctx.grpc_service or "-"
    local method = ctx.grpc_method or "-"
    local status = ctx.grpc_status or "-"
    local latency = ctx.yar_call_latency
    local err_code = ctx.yar_error_code

    local line = string.format(
        "yar_grpc_bridge %s/%s status=%s yar_latency_ms=%.3f",
        service,
        method,
        tostring(status),
        latency and latency * 1000 or 0
    )
    if err_code then
        line = line .. " yar_error=" .. tostring(err_code)
    end
    host.log(host.LOG_INFO, line)
end

return _M
