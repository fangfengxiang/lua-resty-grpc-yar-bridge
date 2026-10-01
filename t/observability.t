use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
# TEST 1-5 各 3 subtest（status+response_body+no_error_log）；
# TEST 6 有 4 subtest（error_log 双 pattern: on_request + on_response hook error）
plan tests => repeat_each() * (3 * 5 + 4 * 1);

run_tests();

__DATA__

=== TEST 1: ensure_request_id — generates request ID when no header
--- config
    set $grpc_status '';
    set $grpc_message '';
    location /t {
        content_by_lua_block {
            local trace = require("resty.yar_grpc_bridge.trace")
            local rid = trace.ensure_request_id()
            ngx.say("rid_set=" .. tostring(ngx.ctx.request_id ~= nil))
            ngx.say("rid_match=" .. tostring(rid == ngx.ctx.request_id))
            ngx.say("rid_len=" .. #ngx.ctx.request_id)
        }
    }
--- request
GET /t
--- response_body
rid_set=true
rid_match=true
rid_len=8
--- no_error_log
[error]

=== TEST 2: ensure_request_id — preserves existing request ID from header
--- config
    set $grpc_status '';
    set $grpc_message '';
    location /t {
        content_by_lua_block {
            local trace = require("resty.yar_grpc_bridge.trace")
            ngx.ctx.request_id = "test-rid-123"
            local rid = trace.ensure_request_id()
            ngx.say("rid=" .. rid)
        }
    }
--- request
GET /t
--- response_body
rid=test-rid-123
--- no_error_log
[error]

=== TEST 3: get_request_id — returns ctx request ID
--- config
    set $grpc_status '';
    set $grpc_message '';
    location /t {
        content_by_lua_block {
            local trace = require("resty.yar_grpc_bridge.trace")
            ngx.ctx.request_id = "my-rid"
            ngx.say("rid=" .. trace.get_request_id())
        }
    }
--- request
GET /t
--- response_body
rid=my-rid
--- no_error_log
[error]

=== TEST 4: error_status — extracts status from Error object
--- config
    set $grpc_status '';
    set $grpc_message '';
    location /t {
        content_by_lua_block {
            local trace = require("resty.yar_grpc_bridge.trace")
            ngx.say("ok=" .. trace.error_status(nil))
            ngx.say("transport=" .. trace.error_status({ code = "TRANSPORT" }))
            ngx.say("timeout=" .. trace.error_status({ code = "TIMEOUT" }))
            ngx.say("unknown_str=" .. trace.error_status("some string"))
            ngx.say("no_code=" .. trace.error_status({}))
        }
    }
--- request
GET /t
--- response_body
ok=ok
transport=transport
timeout=timeout
unknown_str=unknown
no_code=unknown
--- no_error_log
[error]

=== TEST 5: set_hooks — user hooks on_request/on_response invoked
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local f = io.open(pb_dir .. "/test_obs.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local captured_hooks
        local orig_new = require("yar").client.new
        require("yar").client.new = function(uri)
            -- lua-yar client.new 只接受 uri，hooks 经 client:set_options(opts) 传入
            local client = orig_new(uri)
            local orig_set_options = client.set_options
            client.set_options = function(self, opts)
                captured_hooks = opts and opts.hooks
                return orig_set_options(self, opts)
            end
            client.call = function(self, method, params)
                if captured_hooks and captured_hooks.on_request then
                    captured_hooks.on_request(method, params)
                end
                local result = "ok"
                if captured_hooks and captured_hooks.on_response then
                    captured_hooks.on_response(method, result, nil)
                end
                return result
            end
            return client
        end

        _G.hook_calls = { on_request = 0, on_response = 0 }

        require("resty.yar_grpc_bridge").setup {
            hooks = {
                on_request = function(method, params)
                    _G.hook_calls.on_request = _G.hook_calls.on_request + 1
                    _G.hook_calls.req_method = method
                end,
                on_response = function(method, retval, err_obj)
                    _G.hook_calls.on_response = _G.hook_calls.on_response + 1
                    _G.hook_calls.resp_retval = retval
                    _G.hook_calls.resp_err = err_obj
                end,
            },
            services = {
                Echo = { proto = pb_dir .. "/test_obs.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Echo/ {
        add_header grpc-status $grpc_status always;
        add_header grpc-message $grpc_message always;
        content_by_lua_block {
            require("resty.yar_grpc_bridge").serve()
        }
    }
    location /test {
        content_by_lua_block {
            -- repeat_each(2) 每次请求前重置计数器，避免跨请求累积
            _G.hook_calls = { on_request = 0, on_response = 0 }
            local codec = require("yar_grpc.codec")
            local frame = codec.encode_frame("")
            local res = ngx.location.capture("/Echo/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })
            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "0"))
            ngx.say("on_request=" .. _G.hook_calls.on_request)
            ngx.say("on_response=" .. _G.hook_calls.on_response)
            ngx.say("resp_retval=" .. tostring(_G.hook_calls.resp_retval))
            ngx.say("resp_err=" .. tostring(_G.hook_calls.resp_err))
        }
    }
--- request
GET /test
--- response_body
grpc_status=0
on_request=1
on_response=1
resp_retval=ok
resp_err=nil
--- no_error_log
[error]

=== TEST 6: set_hooks — user hook errors are pcall-isolated
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local f = io.open(pb_dir .. "/test_obs.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local captured_hooks
        local orig_new = require("yar").client.new
        require("yar").client.new = function(uri)
            -- lua-yar client.new 只接受 uri，hooks 经 client:set_options(opts) 传入
            local client = orig_new(uri)
            local orig_set_options = client.set_options
            client.set_options = function(self, opts)
                captured_hooks = opts and opts.hooks
                return orig_set_options(self, opts)
            end
            client.call = function(self, method, params)
                if captured_hooks and captured_hooks.on_request then
                    captured_hooks.on_request(method, params)
                end
                local result = "ok"
                if captured_hooks and captured_hooks.on_response then
                    captured_hooks.on_response(method, result, nil)
                end
                return result
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            hooks = {
                on_request = function() error("intentional on_request error") end,
                on_response = function() error("intentional on_response error") end,
            },
            services = {
                Echo = { proto = pb_dir .. "/test_obs.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Echo/ {
        add_header grpc-status $grpc_status always;
        add_header grpc-message $grpc_message always;
        content_by_lua_block {
            require("resty.yar_grpc_bridge").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            local frame = codec.encode_frame("")
            local res = ngx.location.capture("/Echo/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })
            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "0"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=0
--- error_log
on_request hook error
on_response hook error
