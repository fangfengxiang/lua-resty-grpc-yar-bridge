-- lib/resty/yar_grpc_bridge/host.lua
-- OpenResty 宿主环境适配层
-- OpenResty host environment adapter layer
--
-- 集中所有 ngx.* 基础设施 API 调用（Category 1：跨多模块复用的可抽象 API）。
-- 迁移到其他 Lua 宿主时，只需修改此文件 + init.lua（HTTP 框架 API）。
--
-- Centralizes all Category 1 ngx.* infrastructure API calls (reusable across modules).
-- To port to another Lua host, only this file + init.lua (HTTP framework API) need changes.
--
-- Category 2（HTTP 框架 API：ngx.req/header/status/exit/print/socket）
-- 天然属于入口层 init.lua，不在此文件中。
--
-- 设计参考 / Design references:
--   - lua-resty-redis set_socket() 注入模式（库不决定宿主 / library doesn't decide host）
--   - 此项目定位为 SDK（非平台），host.lua 是薄包装层，不是 Kong kong.* 级抽象

local ngx = ngx

---@class yar_grpc_bridge.host
---@field VERSION string
---@field now fun():number
---@field time fun():integer
---@field localtime fun():string
---@field worker_pid fun():integer
---@field ctx table
---@field var table
---@field log fun(level:integer, ...)
---@field LOG_INFO integer
---@field LOG_WARN integer
---@field LOG_ERR integer
---@field shared_dict fun(name:string):table|nil
local _M = {}
_M.VERSION = "0.1.0"

-- 时间 / Time
_M.now = function()
    return ngx.now()
end
_M.time = function()
    return ngx.time()
end
_M.localtime = function()
    return ngx.localtime()
end

-- Worker 信息 / Worker info
_M.worker_pid = function()
    return ngx.worker.pid()
end

-- Per-request context（proxy to ngx.ctx, dynamically resolved per request）
-- ngx.ctx 是 OpenResty 自动 per-request 隔离的 table，
-- 不能在模块加载时捕获（会得到 init 阶段的 ctx），用 proxy metatable 动态转发。
-- ngx.ctx is per-request auto-isolated by OpenResty; cannot be captured at module
-- load time (would get init phase ctx). Proxy metatable forwards dynamically.
_M.ctx = setmetatable({}, {
    __index = function(_, k)
        return ngx.ctx[k]
    end,
    __newindex = function(_, k, v)
        ngx.ctx[k] = v
    end,
})

-- Nginx 变量（proxy to ngx.var, dynamically resolved per request）
-- Nginx variables (proxied to ngx.var, dynamically resolved per request)
_M.var = setmetatable({}, {
    __index = function(_, k)
        return ngx.var[k]
    end,
    __newindex = function(_, k, v)
        ngx.var[k] = v
    end,
})

-- 日志 / Log
_M.log = function(level, ...)
    ngx.log(level, ...)
end

-- 日志级别常量（有限集枚举，ngx.* 级别是数字魔数）
-- Log level constants (finite set enumeration; ngx.* levels are numeric magic numbers)
_M.LOG_INFO = ngx.INFO
_M.LOG_WARN = ngx.WARN
_M.LOG_ERR = ngx.ERR

-- 共享内存 / Shared dictionaries
_M.shared_dict = function(name)
    return ngx.shared[name]
end

return _M
