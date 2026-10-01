# Design Decisions (ADR Index)

> lua-resty-yar-grpc-bridge 架构决策记录索引
> Architecture Decision Records index for lua-resty-yar-grpc-bridge

## 设计哲学

本项目是 **gRPC ↔ YAR 协议桥接库**（非网关），嵌入用户 nginx/OpenResty。
三条原则：

1. **协议忠实** — gRPC over HTTP/2 帧格式和 YAR 协议不可擅改
2. **最小侵入** — 桥接逻辑集中在 content_by_lua，副作用推到 log_by_lua
3. **Lua 惯例** — 遵循 lua-resty-http/redis 等标杆库的 OOP 和错误处理模式

## 决策大纲

| 模块 | 文件 | 决策数 |
|------|------|--------|
| 总体架构 | [overview.md](overview.md) | 4 |
| 帧编解码 | [codec-layer.md](codec-layer.md) | 3 |
| 协议桥接 | [bridge-layer.md](bridge-layer.md) | 7 |
| 错误处理 | [error-layer.md](error-layer.md) | 5 |
| Deadline | [deadline-layer.md](deadline-layer.md) | 2 |
| 熔断器 | [circuit-breaker-layer.md](circuit-breaker-layer.md) | 3（已废弃） |
| 可观测性 | [observability-layer.md](observability-layer.md) | 7 |

**总计：31 个设计决策（其中 7 已废弃）**

## 阅读指南

- 每个决策遵循 ADR 骨架：状态 + 决策驱动因素 + 关联决策 + 背景 + 思考与取舍 + 业界参考 + 代码评价
- 决策编号在模块文件内连续编号（如 codec-1, codec-2, ...）
- 状态：`已采纳` / `已废弃` / `已替代`
