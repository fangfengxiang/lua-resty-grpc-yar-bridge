use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 3 * 2;

run_tests();

__DATA__

=== TEST 1: Multiple gRPC frames → streaming rejection (status 12)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_stream.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Str_SendRequest { string data = 1; }
            message Str_SendResponse { string result = 1; }
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
                Str = { proto = pb_dir .. "/test_stream.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Str/ {
        add_header grpc-status $grpc_status always;
        add_header grpc-message $grpc_message always;
        content_by_lua_block {
            require("resty.yar_grpc_bridge").serve()
        }
    }
    location /test {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")

            -- Two frames = streaming
            local frame1 = codec.encode_frame("first")
            local frame2 = codec.encode_frame("second")
            local body = frame1 .. frame2

            local res = ngx.location.capture("/Str/Send", {
                method = ngx.HTTP_POST,
                body = body,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
            ngx.say("grpc_message=" .. (res.header["grpc-message"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=12
grpc_message=streaming mode not supported
--- no_error_log
[error]

=== TEST 2: Single frame = Unary (not rejected)
--- http_config
    init_by_lua_block {
        local pb_dir = "/tmp"
        local protoc = require("protoc")
        local Yar = require("yar")

        local f = io.open(pb_dir .. "/test_stream2.pb", "wb")
        f:write(protoc.new():compile([[
            syntax = "proto3";
            message Str_SendRequest { string data = 1; }
            message Str_SendResponse { string result = 1; }
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
                Str = { proto = pb_dir .. "/test_stream2.pb", url = "http://mock/api" },
            },
        }
    }
--- config
    set $grpc_status '';
    set $grpc_message '';
    location ~ ^/Str/ {
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

            local payload = pb.encode("Str_SendRequest", { data = "hello" })
            local frame = codec.encode_frame(payload)

            local res = ngx.location.capture("/Str/Send", {
                method = ngx.HTTP_POST,
                body = frame,
            })

            ngx.say("grpc_status=" .. (res.header["grpc-status"] or "nil"))
        }
    }
--- request
GET /test
--- response_body
grpc_status=0
--- no_error_log
[error]
