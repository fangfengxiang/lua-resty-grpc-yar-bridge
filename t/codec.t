use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 3 * 10;

run_tests();

__DATA__

=== TEST 1: decode_frame — normal Unary frame
--- config
    location /t {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            -- 构造一个 gRPC 帧：flag=0, len=5, payload="hello"
            local payload = "hello"
            local frame = string.char(0) .. string.char(0,0,0,5) .. payload
            local flag, pl, size, err = codec.decode_frame(frame)
            ngx.say("flag=" .. tostring(flag))
            ngx.say("payload=" .. pl)
            ngx.say("size=" .. tostring(size))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
flag=0
payload=hello
size=10
err=nil
--- no_error_log
[error]

=== TEST 2: decode_frame — empty message (payload length 0)
--- config
    location /t {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            local frame = string.char(0) .. string.char(0,0,0,0)
            local flag, pl, size, err = codec.decode_frame(frame)
            ngx.say("flag=" .. tostring(flag))
            ngx.say("payload=" .. tostring(pl))
            ngx.say("size=" .. tostring(size))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
flag=0
payload=
size=5
err=nil
--- no_error_log
[error]

=== TEST 3: decode_frame — empty body error
--- config
    location /t {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            local flag, pl, size, err = codec.decode_frame("")
            ngx.say("flag=" .. tostring(flag))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
flag=nil
err=empty request body
--- no_error_log
[error]

=== TEST 4: decode_frame — incomplete header (< 5 bytes)
--- config
    location /t {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            local flag, pl, size, err = codec.decode_frame(string.char(0,0,0))
            ngx.say("flag=" .. tostring(flag))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
flag=nil
err=incomplete gRPC frame header
--- no_error_log
[error]

=== TEST 5: decode_frame — incomplete payload
--- config
    location /t {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            -- 声明 payload 长度 10，但只提供 3 字节
            local frame = string.char(0) .. string.char(0,0,0,10) .. "abc"
            local flag, pl, size, err = codec.decode_frame(frame)
            ngx.say("flag=" .. tostring(flag))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
flag=nil
err=incomplete gRPC frame payload
--- no_error_log
[error]

=== TEST 6: encode_frame — normal payload
--- config
    location /t {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            local frame = codec.encode_frame("hello")
            -- 验证帧头：flag=0, len=5
            local flag = string.byte(frame, 1, 1)
            local len = string.byte(frame,2)*0x1000000 + string.byte(frame,3)*0x10000 + string.byte(frame,4)*0x100 + string.byte(frame,5)
            local payload = string.sub(frame, 6)
            ngx.say("flag=" .. flag)
            ngx.say("len=" .. len)
            ngx.say("payload=" .. payload)
            ngx.say("total=" .. #frame)
        }
    }
--- request
GET /t
--- response_body
flag=0
len=5
payload=hello
total=10
--- no_error_log
[error]

=== TEST 7: encode_frame — empty payload
--- config
    location /t {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            local frame = codec.encode_frame("")
            local flag = string.byte(frame, 1, 1)
            local len = string.byte(frame,2)*0x1000000 + string.byte(frame,3)*0x10000 + string.byte(frame,4)*0x100 + string.byte(frame,5)
            ngx.say("flag=" .. flag)
            ngx.say("len=" .. len)
            ngx.say("total=" .. #frame)
        }
    }
--- request
GET /t
--- response_body
flag=0
len=0
total=5
--- no_error_log
[error]

=== TEST 8: encode_frame + decode_frame roundtrip
--- config
    location /t {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            local original = "test payload data"
            local frame = codec.encode_frame(original)
            local flag, payload, size, err = codec.decode_frame(frame)
            ngx.say("roundtrip=" .. tostring(payload == original))
            ngx.say("flag=" .. tostring(flag))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
roundtrip=true
flag=0
err=nil
--- no_error_log
[error]

=== TEST 9: has_multiple_frames — single frame returns false
--- config
    location /t {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            local payload = "hi"
            local frame = codec.encode_frame(payload)
            local flag, pl, size = codec.decode_frame(frame)
            local multi = codec.has_multiple_frames(frame, size)
            ngx.say("multi=" .. tostring(multi))
        }
    }
--- request
GET /t
--- response_body
multi=false
--- no_error_log
[error]

=== TEST 10: has_multiple_frames — multiple frames returns true
--- config
    location /t {
        content_by_lua_block {
            local codec = require("yar_grpc.codec")
            -- 构造两个帧
            local frame1 = codec.encode_frame("aaa")
            local frame2 = codec.encode_frame("bbb")
            local body = frame1 .. frame2
            local flag, pl, size = codec.decode_frame(body)
            local multi = codec.has_multiple_frames(body, size)
            ngx.say("multi=" .. tostring(multi))
        }
    }
--- request
GET /t
--- response_body
multi=true
--- no_error_log
[error]
