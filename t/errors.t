use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 3 * 13;

run_tests();

__DATA__

=== TEST 1: map_yar_error — transport prefix → UNAVAILABLE (14)
--- config
    location /t {
        content_by_lua_block {
            local errors = require("yar_grpc.errors")
            local status, msg = errors.map_yar_error("transport: connection refused")
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=14
msg=transport: connection refused
--- no_error_log
[error]

=== TEST 2: map_yar_error — timeout prefix → DEADLINE_EXCEEDED (4)
--- config
    location /t {
        content_by_lua_block {
            local errors = require("yar_grpc.errors")
            local status, msg = errors.map_yar_error("timeout: read timeout")
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=4
msg=timeout: read timeout
--- no_error_log
[error]

=== TEST 3: map_yar_error — protocol prefix → INTERNAL (13)
--- config
    location /t {
        content_by_lua_block {
            local errors = require("yar_grpc.errors")
            local status, msg = errors.map_yar_error("protocol: invalid magic number")
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=13
msg=protocol: invalid magic number
--- no_error_log
[error]

=== TEST 4: map_yar_error — no prefix (business error) → INTERNAL (13)
--- config
    location /t {
        content_by_lua_block {
            local errors = require("yar_grpc.errors")
            local status, msg = errors.map_yar_error("method not found: doStuff")
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=13
msg=method not found: doStuff
--- no_error_log
[error]

=== TEST 5: map_yar_error — nil error → INTERNAL (13)
--- config
    location /t {
        content_by_lua_block {
            local errors = require("yar_grpc.errors")
            local status, msg = errors.map_yar_error(nil)
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=13
msg=unknown error
--- no_error_log
[error]

=== TEST 6: map_yar_error — structured Error TRANSPORT → UNAVAILABLE (14)
--- config
    location /t {
        content_by_lua_block {
            local Yar = require("yar")
            local errors = require("yar_grpc.errors")
            local err = Yar.error.new(Yar.error.TRANSPORT, "connection refused")
            local status, msg = errors.map_yar_error(err)
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=14
msg=connection refused
--- no_error_log
[error]

=== TEST 7: map_yar_error — structured Error TIMEOUT → DEADLINE_EXCEEDED (4)
--- config
    location /t {
        content_by_lua_block {
            local Yar = require("yar")
            local errors = require("yar_grpc.errors")
            local err = Yar.error.new(Yar.error.TIMEOUT, "read timeout")
            local status, msg = errors.map_yar_error(err)
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=4
msg=read timeout
--- no_error_log
[error]

=== TEST 8: map_yar_error — structured Error NOT_FOUND → NOT_FOUND (5)
--- config
    location /t {
        content_by_lua_block {
            local Yar = require("yar")
            local errors = require("yar_grpc.errors")
            local err = Yar.error.new(Yar.error.NOT_FOUND, "method not found")
            local status, msg = errors.map_yar_error(err)
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=5
msg=method not found
--- no_error_log
[error]

=== TEST 9: map_yar_error — structured Error EXCEPTION → INTERNAL (13)
--- config
    location /t {
        content_by_lua_block {
            local Yar = require("yar")
            local errors = require("yar_grpc.errors")
            local err = Yar.error.new(Yar.error.EXCEPTION, "server exception")
            local status, msg = errors.map_yar_error(err)
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=13
msg=server exception
--- no_error_log
[error]

=== TEST 10: map_yar_error — structured Error PROTOCOL → INTERNAL (13)
--- config
    location /t {
        content_by_lua_block {
            local Yar = require("yar")
            local errors = require("yar_grpc.errors")
            local err = Yar.error.new(Yar.error.PROTOCOL, "invalid magic number")
            local status, msg = errors.map_yar_error(err)
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=13
msg=invalid magic number
--- no_error_log
[error]

=== TEST 11: map_yar_error — empty string → INTERNAL (13) + "unknown error"
--- config
    location /t {
        content_by_lua_block {
            local errors = require("yar_grpc.errors")
            local status, msg = errors.map_yar_error("")
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=13
msg=unknown error
--- no_error_log
[error]

=== TEST 12: map_yar_error — table with unknown code → INTERNAL (13) fallback
--- config
    location /t {
        content_by_lua_block {
            local errors = require("yar_grpc.errors")
            local err = { code = "UNKNOWN_CODE", message = "something weird" }
            local status, msg = errors.map_yar_error(err)
            ngx.say("status=" .. status)
            ngx.say("msg=" .. msg)
        }
    }
--- request
GET /t
--- response_body
status=13
msg=something weird
--- no_error_log
[error]

=== TEST 13: gRPC status code constants
--- config
    location /t {
        content_by_lua_block {
            local errors = require("yar_grpc.errors")
            ngx.say("OK=" .. errors.OK)
            ngx.say("INVALID_ARGUMENT=" .. errors.INVALID_ARGUMENT)
            ngx.say("DEADLINE_EXCEEDED=" .. errors.DEADLINE_EXCEEDED)
            ngx.say("NOT_FOUND=" .. errors.NOT_FOUND)
            ngx.say("PERMISSION_DENIED=" .. errors.PERMISSION_DENIED)
            ngx.say("UNIMPLEMENTED=" .. errors.UNIMPLEMENTED)
            ngx.say("INTERNAL=" .. errors.INTERNAL)
            ngx.say("UNAVAILABLE=" .. errors.UNAVAILABLE)
        }
    }
--- request
GET /t
--- response_body
OK=0
INVALID_ARGUMENT=3
DEADLINE_EXCEEDED=4
NOT_FOUND=5
PERMISSION_DENIED=7
UNIMPLEMENTED=12
INTERNAL=13
UNAVAILABLE=14
--- no_error_log
[error]
