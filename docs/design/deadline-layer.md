# Deadline 决策

## deadline-1: 前后检查模式（不修改 Client timeout）

**状态：** 已采纳

**决策驱动因素：** persistent Client 模式下无法 per-request `set_options`，不能动态修改 YAR Client 的 timeout。

**背景：** gRPC 客户端通过 `grpc-timeout` header 传递 deadline。原提案设计为"扣除 50ms 桥接开销后设为 Client timeout"，但 persistent Client 的 timeout 在 setup 时固定。

**思考与取舍：**
- **前置检查**（serve 入口）：解析 `grpc-timeout`，若已过期 → 直接返回 `DEADLINE_EXCEEDED`
- **后置检查**（YAR 调用返回后）：若总耗时超过 deadline → 返回 `DEADLINE_EXCEEDED`
- **不修改 Client timeout**：Client 使用 setup 时配置的固定超时作为上限
- 取舍：可能 YAR 调用本身超时（Client timeout）先于 deadline 触发，但这是可接受的——Client timeout 是安全网，deadline 是精确控制

**业界参考：** gRPC 的 deadline propagation 是端到端的；在桥接层，grpc-gateway 通过 context deadline 传递。Lua 无 context，用前后检查近似。

## deadline-2: grpc-timeout header 解析

**状态：** 已采纳

**决策驱动因素：** gRPC over HTTP/2 规范定义的 `grpc-timeout` header 格式。

**背景：** 格式为 `<value><unit>`，unit 取值 H/M/S/m/u/n。

**思考与取舍：**
- `parse_timeout(header)` — 正则匹配 `^(%d+)([HMSmun])$`
- 返回毫秒数（统一单位，便于比较）
- 无 header 或格式非法时返回 nil（静默降级，不报错）
- 单位乘数表 `_UNIT_MULTIPLIERS` 驱动

**业界参考：** [gRPC over HTTP/2 协议规范](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md) — "Timeout is encoded as 8-bit unsigned integer followed by a single character unit."
