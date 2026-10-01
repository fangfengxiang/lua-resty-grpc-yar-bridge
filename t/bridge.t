use Test::Nginx::Socket::Lua;

env_to_nginx("LUA_PATH");
env_to_nginx("LUA_CPATH");

repeat_each(2);
plan tests => repeat_each() * 3 * 16;

run_tests();

__DATA__

=== TEST 1: parse_grpc_path — normal path
--- config
    location /t {
        content_by_lua_block {
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local service, method, err = bridge.parse_grpc_path("/Calculator/Add")
            ngx.say("service=" .. service)
            ngx.say("method=" .. method)
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
service=Calculator
method=Add
err=nil
--- no_error_log
[error]

=== TEST 2: parse_grpc_path — invalid path (single segment)
--- config
    location /t {
        content_by_lua_block {
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local service, method, err = bridge.parse_grpc_path("/foo")
            ngx.say("service=" .. tostring(service))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
service=nil
err=invalid gRPC path: /foo
--- no_error_log
[error]

=== TEST 3: parse_grpc_path — invalid path (three segments)
--- config
    location /t {
        content_by_lua_block {
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local service, method, err = bridge.parse_grpc_path("/foo/bar/baz")
            ngx.say("service=" .. tostring(service))
            ngx.say("err=" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
service=nil
err=invalid gRPC path: /foo/bar/baz
--- no_error_log
[error]

=== TEST 4: method_to_yar — first letter lowercase
--- config
    location /t {
        content_by_lua_block {
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            ngx.say(bridge.method_to_yar("Add"))
            ngx.say(bridge.method_to_yar("GetUser"))
            ngx.say(bridge.method_to_yar("getUser"))
            ngx.say(bridge.method_to_yar("a"))
        }
    }
--- request
GET /t
--- response_body
add
getUser
getUser
a
--- no_error_log
[error]

=== TEST 5: extract_params — multi params by field number
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():load([[
                syntax = "proto3";
                message Test_AddRequest { int32 a = 1; int32 b = 2; }
            ]])
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local decoded = { a = 10, b = 20 }
            local params = bridge.extract_params(decoded, "Test_AddRequest")
            ngx.say("params[1]=" .. params[1])
            ngx.say("params[2]=" .. params[2])
            ngx.say("count=" .. #params)
        }
    }
--- request
GET /t
--- response_body
params[1]=10
params[2]=20
count=2
--- no_error_log
[error]

=== TEST 6: extract_params — single param
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():load([[
                syntax = "proto3";
                message Test_GetRequest { int32 id = 1; }
            ]])
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local decoded = { id = 42 }
            local params = bridge.extract_params(decoded, "Test_GetRequest")
            ngx.say("params[1]=" .. params[1])
            ngx.say("count=" .. #params)
        }
    }
--- request
GET /t
--- response_body
params[1]=42
count=1
--- no_error_log
[error]

=== TEST 7: extract_params — empty params (no fields)
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():load([[
                syntax = "proto3";
                message Test_EmptyRequest {}
            ]])
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local params = bridge.extract_params({}, "Test_EmptyRequest")
            ngx.say("count=" .. #params)
        }
    }
--- request
GET /t
--- response_body
count=0
--- no_error_log
[error]

=== TEST 8: map_response — scalar retval → { result = retval }
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():load([[
                syntax = "proto3";
                message Test_AddResponse { int32 result = 1; }
            ]])
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local result = bridge.map_response(42, "Test_AddResponse")
            ngx.say("result=" .. result.result)
            ngx.say("type=" .. type(result))
        }
    }
--- request
GET /t
--- response_body
result=42
type=table
--- no_error_log
[error]

=== TEST 9: map_response — associative table → direct use
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():load([[
                syntax = "proto3";
                message Test_GetUserResponse { string name = 1; int32 age = 2; }
            ]])
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local retval = { name = "alice", age = 18 }
            local result = bridge.map_response(retval, "Test_GetUserResponse")
            ngx.say("name=" .. result.name)
            ngx.say("age=" .. result.age)
        }
    }
--- request
GET /t
--- response_body
name=alice
age=18
--- no_error_log
[error]

=== TEST 10: map_response — nil retval → empty table
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():load([[
                syntax = "proto3";
                message Test_EmptyResponse {}
            ]])
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local result = bridge.map_response(nil, "Test_EmptyResponse")
            local count = 0
            for _ in pairs(result) do count = count + 1 end
            ngx.say("count=" .. count)
        }
    }
--- request
GET /t
--- response_body
count=0
--- no_error_log
[error]

=== TEST 11: map_response — index array → field 1 (repeated) as key
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():load([[
                syntax = "proto3";
                message Test_ListResponse { repeated string items = 1; }
            ]])
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local retval = { "a", "b", "c" }
            local result = bridge.map_response(retval, "Test_ListResponse")
            ngx.say("items_count=" .. #result.items)
            ngx.say("items[1]=" .. result.items[1])
            ngx.say("items[2]=" .. result.items[2])
            ngx.say("items[3]=" .. result.items[3])
        }
    }
--- request
GET /t
--- response_body
items_count=3
items[1]=a
items[2]=b
items[3]=c
--- no_error_log
[error]

=== TEST 12: map_response — index array with non-repeated field 1, repeated field 2
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            require("pb")
            protoc.new():load([[
                syntax = "proto3";
                message Test_NonRepResponse { int32 count = 1; repeated string names = 2; }
            ]])
            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            local retval = { "alice", "bob" }
            local result = bridge.map_response(retval, "Test_NonRepResponse")
            -- field 1 is "count" (not repeated), so falls back to first repeated "names"
            ngx.say("names_count=" .. #result.names)
            ngx.say("names[1]=" .. result.names[1])
            ngx.say("names[2]=" .. result.names[2])
        }
    }
--- request
GET /t
--- response_body
names_count=2
names[1]=alice
names[2]=bob
--- no_error_log
[error]

=== TEST 13: Client cache — same service reuses Client instance
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            local pb = require("pb")
            local Yar = require("yar")

            protoc.new():load([[
                syntax = "proto3";
                message CacheTest_PingRequest {}
                message CacheTest_PingResponse { string result = 1; }
            ]])

            local new_count = 0
            local orig_new = Yar.client.new
            Yar.client.new = function(uri)
                new_count = new_count + 1
                local client = orig_new(uri)
                client.call = function(self, method, params)
                    return "ok"
                end
                return client
            end

            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            bridge.clear_cache()

            local config = { url = "http://mock/api", options = {} }
            local payload = pb.encode("CacheTest_PingRequest", {})

            -- First call: creates Client (cache miss)
            bridge.handle("CacheTest", "Ping", payload, config)
            ngx.say("new_count_after_1=" .. new_count)

            -- Second call: reuses cached Client (cache hit)
            bridge.handle("CacheTest", "Ping", payload, config)
            ngx.say("new_count_after_2=" .. new_count)
        }
    }
--- request
GET /test
--- response_body
new_count_after_1=1
new_count_after_2=1
--- no_error_log
[error]

=== TEST 14: clear_cache — clears Client cache so next call creates new Client
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            local pb = require("pb")
            local Yar = require("yar")

            protoc.new():load([[
                syntax = "proto3";
                message ClearTest_PingRequest {}
                message ClearTest_PingResponse { string result = 1; }
            ]])

            local new_count = 0
            local orig_new = Yar.client.new
            Yar.client.new = function(uri)
                new_count = new_count + 1
                local client = orig_new(uri)
                client.call = function(self, method, params)
                    return "ok"
                end
                return client
            end

            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            bridge.clear_cache()

            local config = { url = "http://mock/api", options = {} }
            local payload = pb.encode("ClearTest_PingRequest", {})

            -- First call: creates Client
            bridge.handle("ClearTest", "Ping", payload, config)
            ngx.say("new_count_after_1=" .. new_count)

            -- Clear cache
            bridge.clear_cache()

            -- Second call: creates new Client (cache was cleared)
            bridge.handle("ClearTest", "Ping", payload, config)
            ngx.say("new_count_after_2=" .. new_count)
        }
    }
--- request
GET /test
--- response_body
new_count_after_1=1
new_count_after_2=2
--- no_error_log
[error]

=== TEST 15: Client.new failure → returns INTERNAL error
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            local pb = require("pb")
            local Yar = require("yar")

            protoc.new():load([[
                syntax = "proto3";
                message FailNew_PingRequest {}
                message FailNew_PingResponse { string result = 1; }
            ]])

            Yar.client.new = function(uri)
                error("boom")
            end

            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            bridge.clear_cache()

            local config = { url = "http://mock/api", options = {} }
            local payload = pb.encode("FailNew_PingRequest", {})

            local resp, status, err = bridge.handle("FailNew", "Ping", payload, config)
            ngx.say("resp=" .. tostring(resp))
            ngx.say("status=" .. tostring(status))
            ngx.say("err_contains=" .. (string.find(err or "", "failed to create") and "yes" or "no"))
        }
    }
--- request
GET /test
--- response_body
resp=nil
status=13
err_contains=yes
--- no_error_log
[error]

=== TEST 16: hooks injection — hooks passed to set_options and ngx.ctx writes
--- config
    location /t {
        content_by_lua_block {
            local protoc = require("protoc")
            local pb = require("pb")
            local Yar = require("yar")

            protoc.new():load([[
                syntax = "proto3";
                message HookTest_PingRequest {}
                message HookTest_PingResponse { string result = 1; }
            ]])

            local captured_hooks
            local orig_new = Yar.client.new
            Yar.client.new = function(uri)
                local client = orig_new(uri)
                client.set_options = function(self, opts)
                    captured_hooks = opts.hooks
                end
                client.call = function(self, method, params)
                    return "ok"
                end
                return client
            end

            local bridge = require("resty.yar_grpc_bridge.grpc2yar")
            bridge.clear_cache()

            local config = { url = "http://mock/api", options = {} }
            local payload = pb.encode("HookTest_PingRequest", {})

            bridge.handle("HookTest", "Ping", payload, config)

            -- 验证 hooks 被传递
            ngx.say("hooks_set=" .. (captured_hooks and "yes" or "no"))
            ngx.say("on_request=" .. (captured_hooks and captured_hooks.on_request and "yes" or "no"))
            ngx.say("on_response=" .. (captured_hooks and captured_hooks.on_response and "yes" or "no"))

            -- 功能验证：直接调用 hooks 验证 ngx.ctx 写入
            captured_hooks.on_request("add", {1, 2})
            ngx.say("yar_method=" .. tostring(ngx.ctx.yar_method))
            ngx.say("has_start=" .. tostring(ngx.ctx.yar_call_start ~= nil))

            captured_hooks.on_response("add", 3, nil)
            ngx.say("has_latency=" .. tostring(ngx.ctx.yar_call_latency ~= nil))
            ngx.say("err_code=" .. tostring(ngx.ctx.yar_error_code))

            -- 验证 err_obj 路径
            local fake_err = { code = "TRANSPORT", message = "refused" }
            captured_hooks.on_response("add", nil, fake_err)
            ngx.say("err_code=" .. tostring(ngx.ctx.yar_error_code))
        }
    }
--- request
GET /t
--- response_body
hooks_set=yes
on_request=yes
on_response=yes
yar_method=add
has_start=true
has_latency=true
err_code=nil
err_code=TRANSPORT
--- no_error_log
[error]
