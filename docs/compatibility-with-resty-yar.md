# 与 lua-resty-yar 共存兼容性

## 结论

lua-resty-yar-grpc-bridge 与 lua-resty-yar **可在同一 OpenResty 进程兼容共存**。

两者定位互补（gRPC↔Yar 协议桥接 vs OpenResty Yar RPC 框架），模块命名空间、shared_dict、nginx location 均不冲突。唯一摩擦是共享底层 lua-yar 协议库单例时的全局状态注入。

## 共享依赖

两者都 `require("yar")`，即依赖底层 lua-yar 纯 Lua 协议库。lua-yar 把 socket provider 和 log writer/level 设计为**进程级全局单例**（per-VM），任何共享它的上层库都会触碰这些全局状态。这是 lua-yar 作为协议库的合理设计，非缺陷。

## 不冲突维度

| 维度 | yar-grpc-bridge | lua-resty-yar | 结论 |
|------|-----------------|---------------|------|
| 模块命名空间 | `resty.yar_grpc_bridge.*` | `resty.yar.*` | 不冲突 |
| shared_dict | 无（熔断器移除后） | `yar_metrics` | 不冲突 |
| nginx location | 各自 `content_by_lua` | 各自 `content_by_lua` | 不冲突 |
| 定位 | gRPC↔Yar 协议转换 | OpenResty Yar RPC 框架 | 互补，非重叠 |

## 全局状态注入

两者 `setup()` 都操作 lua-yar 全局单例：

```lua
-- yar-grpc-bridge init.lua setup()
Yar.client.set_socket(ngx.socket)
Yar.log.set_writer(function(lvl, msg) ... end)   -- 前缀 "yar: "
Yar.log.set_level(opts.log_level or Yar.log.WARN)

-- lua-resty-yar init.lua setup()
Client.set_socket(ngx.socket)
Log.set_writer(function(lvl, msg) ... end)        -- 前缀 "[yar] "
Log.set_level(lvl)
```

逐项分析：

| 全局状态 | 是否冲突 | 理由 |
|----------|----------|------|
| `set_socket` | **无冲突** | 两者都注入 `ngx.socket`，幂等，谁后调都一样 |
| `set_writer` | **覆盖** | 前缀不同（`"yar: "` vs `"[yar] "`），后调用覆盖前调用 |
| `set_level` | **覆盖** | 后调用的 level 生效 |

## 共存使用约定

1. **socket 无需协调** —— 两者都注入 `ngx.socket`，天然幂等。
2. **log writer/level 需约定** —— 二选一：
   - (a) 只在一处 `setup` 做 log 注入（推荐：让 lua-resty-yar 管 log，bridge 不重复注入）
   - (b) 接受"后 setup 者覆盖"，按 `init_by_lua` 调用顺序控制最终生效方

## 设计取舍

bridge 自做 socket/log 注入是为了**独立可用**（不依赖 lua-resty-yar 也能跑）。这是 OPM 包应具备的独立性。

**不建议**为了让 bridge "感知" lua-resty-yar 而加检测逻辑（如"若 resty.yar 已注入则 skip"）——这会破坏 bridge 独立性，引入隐式耦合，得不偿失。保持两者各自独立 `setup`，通过本文档约定协调方式，把协调权交给用户。

## 参考

- 熔断器移除决策：[design/circuit-breaker-layer.md](design/circuit-breaker-layer.md)（已废弃）
- bridge API：[api.md](api.md)
