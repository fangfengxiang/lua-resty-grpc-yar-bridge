use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 3 * 11;

run_tests();

__DATA__

=== TEST 1: Service not found → status 5 (NOT_FOUND)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_err.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params) return "ok" end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Echo = { proto = pb_dir .. "/test_err.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/[^/]+/ {
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

            local res = ngx.location.capture("/Unknown/Ping", {
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
grpc_status=5
grpc_message=service not found: Unknown
--- no_error_log
[error]

=== TEST 2: Invalid gRPC path → status 3 (INVALID_ARGUMENT)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_err2.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params) return "ok" end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Echo = { proto = pb_dir .. "/test_err2.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location /grpc {
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

            -- Path with only one segment (invalid)
            local res = ngx.location.capture("/grpc", {
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

=== TEST 3: Compression flag → status 12 (UNIMPLEMENTED)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_err3.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params) return "ok" end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Echo = { proto = pb_dir .. "/test_err3.pb", url = "http://mock/api" },
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
            -- Construct frame with compression flag = 1
            local compressed_frame = string.char(1) .. string.char(
                math.floor(5 / 0x1000000) % 0x100,
                math.floor(5 / 0x10000) % 0x100,
                math.floor(5 / 0x100) % 0x100,
                5 % 0x100) .. "hello"

            local res = ngx.location.capture("/Echo/Ping", {
                method = ngx.HTTP_POST,
                body = compressed_frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
            ngx.say("grpc_message=" .. (res.header["grpc-message"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=12
grpc_message=compression not supported
--- no_error_log
[error]

=== TEST 4: Empty body → status 13 (INTERNAL)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_err4.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params) return "ok" end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Echo = { proto = pb_dir .. "/test_err4.pb", url = "http://mock/api" },
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
            -- Empty body
            local res = ngx.location.capture("/Echo/Ping", {
                method = ngx.HTTP_POST,
                body = "",
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

=== TEST 5: Missing proto field → setup error
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local ok, err = pcall(require("resty.yar_grpc_bridge").setup, {
            services = {
                Bad = { url = "http://mock/api" },
            },
        })
        if not ok then
            _G.setup_err = err
        end
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location /test {
        content_by_lua_block {
            ngx.say(_G.setup_err or "no error")
        }
    }
--- request
GET /test
--- response_body
yar_grpc_bridge: service 'Bad' is missing or has invalid 'proto' field
--- no_error_log
[error]

=== TEST 6: Missing url field → setup error
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local f = io.open(pb_dir .. "/test_nourl.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message NoUrl_PingRequest {}
            message NoUrl_PingResponse { string result = 1; }
        ]]))
        f:close()

        local ok, err = pcall(require("resty.yar_grpc_bridge").setup, {
            services = {
                NoUrl = { proto = pb_dir .. "/test_nourl.pb" },
            },
        })
        if not ok then
            _G.setup_err = err
        end
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location /test {
        content_by_lua_block {
            ngx.say(_G.setup_err or "no error")
        }
    }
--- request
GET /test
--- response_body
yar_grpc_bridge: service 'NoUrl' is missing or has invalid 'url' field
--- no_error_log
[error]

=== TEST 7: options not a table → setup error
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local f = io.open(pb_dir .. "/test_badopt.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message BadOpt_PingRequest {}
            message BadOpt_PingResponse { string result = 1; }
        ]]))
        f:close()

        local ok, err = pcall(require("resty.yar_grpc_bridge").setup, {
            services = {
                BadOpt = { proto = pb_dir .. "/test_badopt.pb", url = "http://mock/api", options = "not_a_table" },
            },
        })
        if not ok then
            _G.setup_err = err
        end
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location /test {
        content_by_lua_block {
            ngx.say(_G.setup_err or "no error")
        }
    }
--- request
GET /test
--- response_body
yar_grpc_bridge: service 'BadOpt' options must be a table
--- no_error_log
[error]

=== TEST 8: Structured YAR Error (TRANSPORT) → status 14 (UNAVAILABLE)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_err8.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest {}
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = Yar.client.new
        Yar.client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params)
                return nil, Yar.error.new(Yar.error.TRANSPORT, "connection refused")
            end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Echo = { proto = pb_dir .. "/test_err8.pb", url = "http://mock/api" },
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

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
            ngx.say("grpc_message=" .. (res.header["grpc-message"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=14
grpc_message=connection refused
--- no_error_log
[error]

=== TEST 9: Corrupt .pb descriptor → setup fail-fast (Bug 1)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local f = io.open(pb_dir .. "/test_corrupt.pb", "wb")
        f:write("this is not a valid protobuf descriptor")
        f:close()

        local ok, err = pcall(require("resty.yar_grpc_bridge").setup, {
            services = {
                Bad = { proto = pb_dir .. "/test_corrupt.pb", url = "http://mock/api" },
            },
        })
        if not ok then
            _G.setup_err = err
        end
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location /test {
        content_by_lua_block {
            ngx.say(_G.setup_err or "no error")
        }
    }
--- request
GET /test
--- response_body_like eval
qr/invalid \.pb descriptor/
--- no_error_log
[error]

=== TEST 10: Request body over limit → RESOURCE_EXHAUSTED (8) (P0-4)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local f = io.open(pb_dir .. "/test_limit.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Echo_PingRequest { string name = 1; }
            message Echo_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = require("yar").client.new
        require("yar").client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params) return "ok" end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            max_payload_bytes = 100,
            services = {
                Echo = { proto = pb_dir .. "/test_limit.pb", url = "http://mock/api" },
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
            -- 200 bytes payload, well over 100 byte limit
            local payload = string.rep("x", 200)
            local frame = codec.encode_frame(payload)

            local res = ngx.location.capture("/Echo/Ping", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=8
--- no_error_log
[error]

=== TEST 11: Message field missing → INVALID_ARGUMENT (3) (Bug 3)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local f = io.open(pb_dir .. "/test_msgfield.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Inner { int32 x = 1; }
            message Test_PingRequest {
              int32 a = 1;
              Inner b = 2;
              int32 c = 3;
            }
            message Test_PingResponse { string result = 1; }
        ]]))
        f:close()

        local orig_new = require("yar").client.new
        require("yar").client.new = function(uri)
            local client = orig_new(uri)
            client.call = function(self, method, params) return "ok" end
            return client
        end

        require("resty.yar_grpc_bridge").setup {
            services = {
                Test = { proto = pb_dir .. "/test_msgfield.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Test/ {
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

            -- Encode Test_PingRequest with a=1, c=3, but b (message type) not set
            local payload = pb.encode("Test_PingRequest", { a = 1, c = 3 })
            local frame = codec.encode_frame(payload)

            local res = ngx.location.capture("/Test/Ping", {
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
