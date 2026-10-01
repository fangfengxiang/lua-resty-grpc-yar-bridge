-- lib/resty/yar_grpc_bridge/yar2grpc.lua
-- YAR → gRPC 方向桥接入口层
-- Entry layer for the Yar → gRPC bridge.
-- 接受 YAR 协议请求，转换为 gRPC 调用，返回 YAR 协议响应。
--
-- 纯协议转换（pack_params/pb.encode/encode_frame/decode_frame/pb.decode/extract_result）
-- 已委托核心 lua-yar-grpc 的 forward.encode_request / forward.decode_response。
-- 入口层只保留：grpc_transport 注入 + 调用编排 + Yar Server HTTP I/O 装配。
--
-- 设计思路：
--   利用 lua-yar Server 的 {method, data, writer} HTTP 模式解析 YAR 协议，
--   注入一个动态 proxy service，其方法将 YAR 位置参数转换为 protobuf message，
--   通过注入的 grpc_transport 发送到 Go gRPC 后端，再将响应转回 YAR retval。
--
-- 依赖注入设计（对标 lua-yar set_socket / set_http_provider 模式）：
--   set_grpc_transport(fn)  — 注入 gRPC 传输层可调用对象
--   默认实现：ngx.location.capture + grpc_pass（nginx 内部代理到 gRPC upstream）

local ngx = ngx
local Yar = require("yar")
local errors = require("yar_grpc.errors")
local grpc_converter = require("yar_grpc.grpc_converter")
local core_forward = require("yar_grpc.forward")

---@class yar_grpc_bridge.yar2grpc
local _M = {}

-- gRPC 状态码 → YAR Error code 常量映射（有限集，用常量对齐 lua-yar Error）
local _GRPC_STATUS_TO_YAR_CODE = {
    [errors.UNAVAILABLE] = Yar.error.TRANSPORT,
    [errors.DEADLINE_EXCEEDED] = Yar.error.TIMEOUT,
    [errors.INVALID_ARGUMENT] = Yar.error.PROTOCOL,
    [errors.NOT_FOUND] = Yar.error.NOT_FOUND,
}

-- 注入的 gRPC 传输层可调用对象
-- 签名：transport(service, method, payload) -> payload|nil, status, err
local _grpc_transport = nil

-- 服务配置：{ [service_name] = { proto=string, methods={method1, ...}, url=string } }
local _services = {}

-- 已注册的 proxy service：按 service 分组，每个 service 一个 {yar_method → 闭包} 子表
-- handle() 从 URL path 解析 service 名选子表，YAR method 保持纯名（PHP client 无感知）
local _proxy_services = {}

--- 注入 gRPC 传输层可调用对象
-- 对标 lua-yar Yar.client.set_socket(ngx.socket) 注入模式
-- 库不决定传输层实现，由宿主注入
---@param fn function grpc_transport(service, method, payload) -> payload|nil, status, err
function _M.set_grpc_transport(fn)
    _grpc_transport = fn
end

--- 配置反向桥接服务
-- 在 init_by_lua_block 中调用，加载 proto + 注册 proxy service 方法
---@param opts table { services=table, grpc_transport=function|nil }
---@return yar_grpc_bridge.yar2grpc self（链式）
function _M.setup(opts)
    opts = opts or {}
    _services = opts.services or {}

    if opts.grpc_transport then
        _grpc_transport = opts.grpc_transport
    end

    -- 构建 proxy service：按 service 分组，每个 service 一个 {yar_method → 闭包} 子表。
    -- 多 service 同名 method 互不冲突（各在独立子表）；handle() 从 URL path
    -- 解析 service 名选子表，YAR method 保持纯方法名（PHP client 无感知，
    -- 仅 URL path 携带 service：new Yar_Client("http://bridge/api/Calculator")）。
    _proxy_services = {}
    for service_name, svc in pairs(_services) do
        local methods = svc.methods or {}
        _proxy_services[service_name] = {}
        for _, grpc_method in ipairs(methods) do
            local yar_method = grpc_converter.method_to_yar(grpc_method)
            -- 同 service 内同名 method 冲突（gRPC proto 不允许，配置错误）
            if _proxy_services[service_name][yar_method] then
                error("yar2grpc: duplicate method '" .. yar_method .. "' in service '" .. service_name .. "'", 0)
            end
            -- 闭包捕获 service_name 和 grpc_method
            _proxy_services[service_name][yar_method] = function(...)
                return _M._dispatch(service_name, grpc_method, { ... })
            end
        end
    end

    return _M
end

--- 内部分发：核心 encode_request → grpc_transport → 核心 decode_response
-- 纯协议转换委托核心 yar_grpc.forward，入口层只做 transport 编排 + 调用。
---@param service string gRPC Service 名
---@param method string gRPC Method 名
---@param params table YAR 位置参数数组
---@return any result YAR retval
---@return table|nil err 错误对象（失败时）
function _M._dispatch(service, method, params)
    if not _grpc_transport then
        return nil, { code = Yar.error.EXCEPTION, message = "grpc transport not injected" }
    end

    -- 1. 核心编码 YAR params → gRPC 帧（pack_params + pb.encode + encode_frame）
    local frame, enc_err = core_forward.encode_request(service, method, params)
    if not frame then
        return nil, { code = Yar.error.EXCEPTION, message = "encode failed: " .. tostring(enc_err) }
    end

    -- 2. 调用 gRPC 传输层（pcall 隔离注入函数，鸭子类型第零步）
    -- _grpc_transport 是宿主注入的外部函数，不可控，必须 pcall 包裹
    local ok_transport, resp_payload, grpc_status, err = pcall(_grpc_transport, service, method, frame)
    if not ok_transport then
        return nil, { code = Yar.error.TRANSPORT, message = "grpc transport error: " .. tostring(resp_payload) }
    end
    if err or (grpc_status and grpc_status ~= errors.OK) then
        local code = (grpc_status and _GRPC_STATUS_TO_YAR_CODE[grpc_status]) or Yar.error.EXCEPTION
        return nil, { code = code, message = err or ("gRPC status: " .. tostring(grpc_status)) }
    end

    -- 3. 核心解码 gRPC 响应 → YAR retval（decode_frame + pb.decode + extract_result）
    -- decode_response 返回 retval, err；retval 可能为 nil（合法 YAR 返回值），
    -- 仅当 retval==nil 且 err~=nil 时才是出错。
    local result, dec_err = core_forward.decode_response(service, method, resp_payload)
    if result == nil and dec_err then
        return nil, { code = Yar.error.PROTOCOL, message = dec_err }
    end
    return result
end

--- 处理 YAR 请求（在 content_by_lua_block 中调用）
-- 利用 Yar Server 的 HTTP 模式解析 YAR 协议 + 分发到 proxy service
---@return string|nil yar_response YAR 协议响应体
---@return string|nil err 错误信息
function _M.handle()
    if not _grpc_transport then
        return nil, "grpc transport not injected, call set_grpc_transport() first"
    end

    -- service 名由 nginx location 的 named capture `service_name` 提取（声明式解析），
    -- 部署方在 nginx 配置里决定 path 前缀规则；lua 端只消费 ngx.var.service_name。
    -- 拿不到（location 未配 capture 或直接调用）直接报错，不做 yar→pb。
    local service_name = ngx.var.service_name
    if not service_name or service_name == "" then
        ngx.status = ngx.HTTP_BAD_REQUEST
        ngx.header["Content-Type"] = "text/plain"
        ngx.say(
            "yar2grpc: service_name nginx variable not set; configure location with named capture (?<service_name>...)"
        )
        return
    end
    local proxy = _proxy_services[service_name]
    if not proxy then
        ngx.status = ngx.HTTP_NOT_FOUND
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("yar2grpc: service not registered: " .. service_name)
        return
    end

    -- 确保 body 已读取（含 disk spill 处理，对标 init.lua serve() 的 body file 回退）
    -- 当请求体超过 client_body_buffer_size 时 get_body_data() 返回 nil，数据写入临时文件
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "rb")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end

    -- 用该 service 的 proxy 子表创建 Yar Server（纯 method 查子表，多 service 互不冲突）
    local server = Yar.server.new(proxy)

    -- HTTP 模式：{method, data, writer}
    -- server:handle 返回 true|nil, err，检查返回值不再吞掉错误
    local ok, herr = server:handle({
        method = ngx.req.get_method(),
        data = body or "",
        writer = function(status, headers, response_body)
            ngx.status = status
            for k, v in pairs(headers or {}) do
                ngx.header[k] = v
            end
            ngx.print(response_body or "")
        end,
    })

    if not ok then
        -- server:handle 返回 nil, err：输出 HTTP 500 给客户端
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.header["content-type"] = "text/plain"
        ngx.print("yar server error: " .. tostring(herr))
        return nil, tostring(herr)
    end

    return true
end

return _M
