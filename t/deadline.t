use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 3 * 11;

run_tests();

__DATA__

=== TEST 1: parse_timeout — milliseconds unit (m)
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local ms = deadline.parse_timeout("100m")
            ngx.say("ms=" .. tostring(ms))
        }
    }
--- request
GET /t
--- response_body
ms=100
--- no_error_log
[error]

=== TEST 2: parse_timeout — seconds unit (S)
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local ms = deadline.parse_timeout("5S")
            ngx.say("ms=" .. tostring(ms))
        }
    }
--- request
GET /t
--- response_body
ms=5000
--- no_error_log
[error]

=== TEST 3: parse_timeout — hours unit (H)
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local ms = deadline.parse_timeout("1H")
            ngx.say("ms=" .. tostring(ms))
        }
    }
--- request
GET /t
--- response_body
ms=3600000
--- no_error_log
[error]

=== TEST 4: parse_timeout — minutes unit (M)
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local ms = deadline.parse_timeout("2M")
            ngx.say("ms=" .. tostring(ms))
        }
    }
--- request
GET /t
--- response_body
ms=120000
--- no_error_log
[error]

=== TEST 5: parse_timeout — microseconds unit (u)
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local ms = deadline.parse_timeout("500000u")
            ngx.say("ms=" .. tostring(ms))
        }
    }
--- request
GET /t
--- response_body
ms=500
--- no_error_log
[error]

=== TEST 6: parse_timeout — nil header returns nil
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local ms = deadline.parse_timeout(nil)
            ngx.say("ms=" .. tostring(ms))
        }
    }
--- request
GET /t
--- response_body
ms=nil
--- no_error_log
[error]

=== TEST 7: parse_timeout — invalid format returns nil
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local ms = deadline.parse_timeout("abc")
            ngx.say("ms=" .. tostring(ms))
        }
    }
--- request
GET /t
--- response_body
ms=nil
--- no_error_log
[error]

=== TEST 8: check_front — no deadline returns false
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local start = ngx.now()
            local expired = deadline.check_expired(nil, start, ngx.now())
            ngx.say("expired=" .. tostring(expired))
        }
    }
--- request
GET /t
--- response_body
expired=false
--- no_error_log
[error]

=== TEST 9: check_back — no deadline returns false
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local start = ngx.now()
            local exceeded = deadline.check_expired(nil, start, ngx.now())
            ngx.say("exceeded=" .. tostring(exceeded))
        }
    }
--- request
GET /t
--- response_body
exceeded=false
--- no_error_log
[error]

=== TEST 10: check_front — zero deadline returns true (already expired)
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local start = ngx.now() - 1  -- 1 second ago
            local expired = deadline.check_expired(0, start, ngx.now())
            ngx.say("expired=" .. tostring(expired))
        }
    }
--- request
GET /t
--- response_body
expired=true
--- no_error_log
[error]

=== TEST 11: parse_timeout — nanoseconds unit (n)
--- config
    location /t {
        content_by_lua_block {
            local deadline = require("yar_grpc.deadline")
            local ms = deadline.parse_timeout("1000000n")
            ngx.say("ms=" .. tostring(ms))
        }
    }
--- request
GET /t
--- response_body
ms=1
--- no_error_log
[error]
