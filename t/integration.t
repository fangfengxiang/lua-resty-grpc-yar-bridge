use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 3 * 9;

run_tests();

__DATA__

=== TEST 1: Full gRPC → YAR → gRPC flow (mock client, scalar response)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_calc.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Calc_AddRequest { int32 a = 1; int32 b = 2; }
            message Calc_AddResponse { int32 result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                if method == "add" then
                    return (params[1] or 0) + (params[2] or 0)
                end
                return nil, "method not found: " .. method
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Calc = { proto = pb_dir .. "/test_calc.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Calc/ {
        add_header grpc-status $grpc_status always;
        add_header grpc-message $grpc_message always;
        content_by_lua_block {
            require("resty.yar_grpc_bridge").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local pb = require("pb")
            local codec = require("yar_grpc.codec")

            local payload = pb.encode("Calc_AddRequest", { a = 3, b = 4 })
            local frame = codec.encode_frame(payload)

            local res = ngx.location.capture("/Calc/Add", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("http_status=" .. res.status)
            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))

            local flag, resp_payload = codec.decode_frame(res.body)
            if resp_payload then
                local result = pb.decode("Calc_AddResponse", resp_payload)
                ngx.say("result=" .. (result and result.result or "nil"))
            else
                ngx.say("result=decode_failed")
            end
        }
    }
--- request
GET /test
--- response_body
http_status=200
grpc_status=0
result=7
--- no_error_log
[error]

=== TEST 2: Full flow with associative array response
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_user.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message User_GetRequest { int32 id = 1; }
            message User_GetResponse { string name = 1; int32 age = 2; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                if method == "get" then
                    return { name = "alice", age = 18 }
                end
                return nil, "method not found"
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                User = { proto = pb_dir .. "/test_user.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/User/ {
        add_header grpc-status $grpc_status always;
        add_header grpc-message $grpc_message always;
        content_by_lua_block {
            require("resty.yar_grpc_bridge").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local pb = require("pb")
            local codec = require("yar_grpc.codec")

            local payload = pb.encode("User_GetRequest", { id = 1 })
            local frame = codec.encode_frame(payload)

            local res = ngx.location.capture("/User/Get", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))

            local flag, resp_payload = codec.decode_frame(res.body)
            if resp_payload then
                local result = pb.decode("User_GetResponse", resp_payload)
                ngx.say("name=" .. (result and result.name or "nil"))
                ngx.say("age=" .. (result and result.age or "nil"))
            else
                ngx.say("decode=failed")
            end
        }
    }
--- request
GET /test
--- response_body
grpc_status=0
name=alice
age=18
--- no_error_log
[error]

=== TEST 3: YAR call error propagation (transport error → UNAVAILABLE)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_fail.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Fail_PingRequest {}
            message Fail_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                return nil, "transport: connection refused"
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Fail = { proto = pb_dir .. "/test_fail.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Fail/ {
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

            local res = ngx.location.capture("/Fail/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
            ngx.say("grpc_message=" .. (res.header["grpc-message"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=14
grpc_message=transport: connection refused
--- no_error_log
[error]

=== TEST 4: Per-service options override (table config with url + options)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_opt.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Opt_PingRequest {}
            message Opt_PingResponse { string result = 1; }
        ]]))
        f:close()

        -- 记录 per-service options 是否被正确传入
        _G.test_opts = nil

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.set_options = function(self, opts)
                _G.test_opts = opts
            end
            client.call = function(self, method, params)
                return "ok"
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Opt = {
                    proto   = pb_dir .. "/test_opt.pb",
                    url     = "http://mock/api",
                    options = { timeout = 5000, connect_timeout = 1000 },
                },
            },
            yar_options = { timeout = 3000 },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Opt/ {
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

            local res = ngx.location.capture("/Opt/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
            -- per-service timeout=5000 覆盖全局 timeout=3000
            -- connect_timeout=1000 来自 per-service
            ngx.say("timeout=" .. (_G.test_opts and _G.test_opts.timeout or "nil"))
            ngx.say("connect_timeout=" .. (_G.test_opts and _G.test_opts.connect_timeout or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=0
timeout=5000
connect_timeout=1000
--- no_error_log
[error]

=== TEST 5: protobuf decode failure → INVALID_ARGUMENT (3)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_bad.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Bad_PingRequest { int32 x = 1; }
            message Bad_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                return "ok"
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Bad = { proto = pb_dir .. "/test_bad.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Bad/ {
        add_header grpc-status $grpc_status always;
        add_header grpc-message $grpc_message always;
        content_by_lua_block {
            require("resty.yar_grpc_bridge").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")

            -- 发送无效 protobuf payload：field 1 (0x08) + 不完整 varint (0xFF 无终止字节)
            -- pb.decode 读取 field tag 后尝试读 varint 值，但 0xFF 有 continuation bit 却无后续字节
            local bad_payload = string.char(0x08, 0xFF)
            local frame = codec.encode_frame(bad_payload)

            local res = ngx.location.capture("/Bad/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=3
--- no_error_log
[error]

=== TEST 6: Multiple services sharing same .pb file (dedup)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_dedup.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message SvcA_PingRequest {}
            message SvcA_PingResponse { string result = 1; }
            message SvcB_PingRequest {}
            message SvcB_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                return "ok"
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                SvcA = { proto = pb_dir .. "/test_dedup.pb", url = "http://mock/a" },
                SvcB = { proto = pb_dir .. "/test_dedup.pb", url = "http://mock/b" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Svc[AB]/ {
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

            local res_a = ngx.location.capture("/SvcA/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })
            local res_b = ngx.location.capture("/SvcB/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("svc_a=" .. (res_a.header["grpc-status"] or "nil"))
            ngx.say("svc_b=" .. (res_b.header["grpc-status"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
svc_a=0
svc_b=0
--- no_error_log
[error]

=== TEST 7: Persistent Client — multiple requests reuse same Client instance
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_persist.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Persist_PingRequest {}
            message Persist_PingResponse { string result = 1; }
        ]]))
        f:close()

        _G.client_new_count = 0
        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            _G.client_new_count = _G.client_new_count + 1
            local client = orig_new(uri)
            client.call = function(self, method, params)
                return "ok"
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Persist = { proto = pb_dir .. "/test_persist.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Persist/ {
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

            -- First request: creates Client
            local res1 = ngx.location.capture("/Persist/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            -- Second request: reuses cached Client
            local res2 = ngx.location.capture("/Persist/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status_1=" .. (res1.header["grpc-status"] or "nil"))
            ngx.say("grpc_status_2=" .. (res2.header["grpc-status"] or "nil"))
            ngx.say("client_new_count=" .. _G.client_new_count)
        }
    }
--- request
GET /test
--- response_body
grpc_status_1=0
grpc_status_2=0
client_new_count=1
--- no_error_log
[error]

=== TEST 8: deep_merge — nested keepalive options merge correctly
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_merge.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Merge_PingRequest {}
            message Merge_PingResponse { string result = 1; }
        ]]))
        f:close()

        _G.test_opts = nil
        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.set_options = function(self, opts)
                _G.test_opts = opts
            end
            client.call = function(self, method, params)
                return "ok"
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Merge = {
                    proto   = pb_dir .. "/test_merge.pb",
                    url     = "http://mock/api",
                    options = { keepalive = { pool_size = 128 } },
                },
            },
            yar_options = { keepalive = { pool_size = 64, idle_timeout = 60000 } },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Merge/ {
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

            local res = ngx.location.capture("/Merge/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
            -- per-service pool_size=128 overrides global pool_size=64
            -- global idle_timeout=60000 is preserved (deep_merge, not shallow replace)
            ngx.say("pool_size=" .. (_G.test_opts and _G.test_opts.keepalive and _G.test_opts.keepalive.pool_size or "nil"))
            ngx.say("idle_timeout=" .. (_G.test_opts and _G.test_opts.keepalive and _G.test_opts.keepalive.idle_timeout or "nil"))
            ngx.say("persistent=" .. tostring(_G.test_opts and _G.test_opts.persistent))
        }
    }
--- request
GET /test
--- response_body
grpc_status=0
pool_size=128
idle_timeout=60000
persistent=true
--- no_error_log
[error]

=== TEST 9: log_phase — structured log from ngx.ctx metadata
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_log.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Log_PingRequest {}
            message Log_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                return "ok"
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Log = { proto = pb_dir .. "/test_log.pb", url = "http://mock/api" },
            },
            log_level = Yar.log.DEBUG,
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Log/ {
        add_header grpc-status $grpc_status always;
        add_header grpc-message $grpc_message always;
        content_by_lua_block {
            require("resty.yar_grpc_bridge").serve()
        }
        log_by_lua_block {
            require("resty.yar_grpc_bridge").log_phase()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            local proxy = require("resty.yar_grpc_bridge")
            local frame = codec.encode_frame("")

            local res = ngx.location.capture("/Log/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))

            -- 直接测试 log_phase()：设置 ngx.ctx 并 mock ngx.log 捕获输出
            ngx.ctx.grpc_service = "DirectTest"
            ngx.ctx.grpc_method = "Ping"
            ngx.ctx.grpc_status = 0
            ngx.ctx.yar_call_latency = 0.050

            local captured
            local orig_log = ngx.log
            ngx.log = function(level, msg)
                if level == ngx.INFO then
                    captured = msg
                end
            end

            proxy.log_phase()
            ngx.log = orig_log

            ngx.say("log_phase_output=" .. (captured or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=0
log_phase_output=yar_grpc_bridge DirectTest/Ping status=0 yar_latency_ms=50.000
--- no_error_log
[error]
