# 熔断器决策

> **已废弃（2026-09）** — 熔断器已从项目中移除。
>
> 治理职责（熔断/限流）上移到上层（lua-resty-yar 框架层或 Envoy/网关）。
> gRPC 生态共识：熔断是**策略**非**机制**，协议桥接库不应承担。
> 相关代码（`circuit_breaker.lua`）与测试（`t/circuit_breaker.t`）已删除。
> 本文件保留作为决策历史。

## cb-1: 3 态状态机（CLOSED/OPEN/HALF_OPEN）

**状态：** 已废弃

**决策驱动因素：** 经典熔断器模式，隔离故障后端。

**背景：** YAR 后端故障时，继续发请求会导致级联失败。需要熔断器在连续失败后短路请求。

**思考与取舍：**
- **CLOSED**：正常放行，记录连续失败数，达阈值 → OPEN
- **OPEN**：拒绝所有请求，等待冷却时间 → HALF_OPEN
- **HALF_OPEN**：放行有限探测请求，成功 → CLOSED，失败 → OPEN
- 取舍：HALF_OPEN 的探测请求数限制为 1（简单有效），生产可配置

**业界参考：** Michael Nygard《Release It!》的 Circuit Breaker 模式；Hystrix 的 3 态实现。

## cb-2: ngx.shared.DICT 跨 worker 状态

**状态：** 已废弃

**决策驱动因素：** OpenResty 多 worker 进程，熔断器状态需跨 worker 可见。

**背景：** 模块级 table 是 per-worker 的，一个 worker 发现的故障其他 worker 不知道。

**思考与取舍：**
- 优先使用 `ngx.shared.DICT`（生产环境）
- 无 shared dict 时回退到模块级 table（测试环境/降级模式）
- 状态、计数、最后失败时间戳分别用不同 key 存储
- 取舍：shared dict 的 `incr` 是原子操作，但 `get` + `set` 不是——HALF_OPEN 转换可能有竞态，但可接受（最多多放行一个探测请求）

**业界参考：** lua-resty-limit-traffic 的 `ngx.shared.dict` 限流模式；Kong 的 cluster-level 状态用 `kong.cache`。

## cb-3: 仅传输层错误触发熔断

**状态：** 已废弃

**决策驱动因素：** 协议错误是客户端 bug（请求格式错误），不应计入熔断。

**背景：** YAR Error 有 5 种 code：TRANSPORT/TIMEOUT/PROTOCOL/NOT_FOUND/EXCEPTION。

**思考与取舍：**
- 仅 `TRANSPORT` 和 `TIMEOUT` 触发 `record_failure`
- `PROTOCOL` / `NOT_FOUND` / `EXCEPTION` 不计入（客户端问题或服务端业务错误）
- `record_success` 重置失败计数（任何成功调用都表明后端可用）

**业界参考：** Hystrix 的 `recordFailure` 默认对所有异常计数，但可配置 `HystrixCommandProperties.executionIsolationStrategy`。本项目更保守。
