# 变更日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 规范，
版本号采用 [语义化版本](https://semver.org/lang/zh-CN/)（SemVer）。

## [0.1.0] - 2026-10-02

### 变更

- **yar2grpc service 名解析重构为 nginx named capture** — `handle()` 不再 `ngx.var.uri:match()` 解析 path，改读 `ngx.var.service_name`（由 location `(?<service_name>[^/]+)$` 提取）。职责分离：nginx 声明式配置 path 前缀规则，lua 只消费变量；部署方自由决定前缀段数（`/api/X`、`/grpc-service/X`、`/v1/grpc/X`），lua 零改动。详见 ADR [bridge-6](docs/design/bridge-layer.md)。
- **HTTP 状态码统一用 `ngx.HTTP_*` 常量** — yar2grpc handle 的 400/404 改用 `ngx.HTTP_BAD_REQUEST`/`ngx.HTTP_NOT_FOUND`，与同函数 `ngx.HTTP_INTERNAL_SERVER_ERROR` 用法一致，消除裸魔数。
- **service 未注册错误消息修正** — 从 `not found in path` 改为 `not registered: <name>`（此时 service_name 已解析出，语义更准）。

### 新增

- **gRPC ↔ YAR 双向协议桥接**
  - 正向桥接（gRPC → YAR）：`setup()` + `serve()`，接收 gRPC Unary 请求，转换为 YAR 调用转发至 PHP YAR Server
  - 反向桥接（YAR → gRPC）：`yar2grpc.setup()` + `handle()`，接收 YAR 请求，转换为 gRPC 调用转发至 gRPC 后端
  - gRPC 客户端 / YAR 客户端均无需感知对端协议
- **预编译 `.pb` 描述符加载** — 启动时 `pb.load()` 加载二进制描述符，运行时零 `protoc` 依赖；同一文件自动去重
- **约定式映射** — `{Service}_{Method}Request/Response` 消息名 + field number 升序 → YAR 位置参数，无需逐方法配置（命名契约详见 ADR [bridge-7](docs/design/bridge-layer.md)）
- **gRPC 帧编解码** — 标准 5 字节帧头（压缩标志 + 大端长度）+ protobuf payload
- **流式请求拒绝** — Server/Client/Bidi streaming 返回 `grpc-status: 12` (UNIMPLEMENTED)
- **YAR Error → gRPC 状态码自动映射** — `TRANSPORT→UNAVAILABLE`、`TIMEOUT→DEADLINE_EXCEEDED`、`PROTOCOL→INTERNAL`、`NOT_FOUND→NOT_FOUND`
- **Deadline 传播** — 解析 `grpc-timeout` header，入口/出口前后检查是否过期
- **可观测性**
  - 请求 ID 多熵源生成（timestamp + worker pid + counter），8 字符十六进制
  - `log_phase()` 固定格式访问日志（`yar_grpc_bridge svc/method status= yar_latency_ms=`）
  - hooks 透传（`on_request`/`on_response`），pcall 隔离用户 hooks
- **OpenResty cosocket 注入** — 出向 YAR 调用走非阻塞 cosocket，不阻塞 worker
- **persistent Client 模式** — 按 service 名缓存 YAR Client 实例，连接复用
- **`host.lua` 宿主适配层** — 集中所有 `ngx.*` 基础设施 API（`host.now`/`host.ctx`/`host.var`/`host.log`/`host.shared_dict`），核心协议层零 `ngx.*` 依赖
- **DoS 防护** — `max_payload_bytes` 请求体大小上限（Content-Length 预检 + body 兜底 + disk spill 文件大小预检）
- **依赖注入设计** — `grpc_transport` 可调用对象注入，对标 lua-yar `set_socket` / `set_http_provider` 模式
- **错误处理三分类法** — 运行时错误 `return nil, err` / 编程错误 `error(msg, 0)` / 不可控第三方 API `pcall` 包裹
- **ADR 设计文档** — 31 个架构决策记录（总体架构 / 帧编解码 / 协议桥接 / 错误处理 / Deadline / 可观测性）
- **测试套件**
  - BDD 单元/集成测试（test-nginx，464 tests）
  - e2e 端到端测试（真实 PHP Yar ↔ 真实 Go gRPC 双向互操作，JSON / Msgpack 双打包器）
  - e2e 404 错误路径覆盖（curl 打未注册 service 断言 HTTP 404 + 正确消息）
  - e2e 单 worker 交叉并发隔离验证（N 个 PHP yar client 打正常 service + N 个 curl 打不存在 service 并发，断言 PHP 全 PASS + curl 全 404，证伪 `ngx.var.service_name` 跨请求读串）
  - e2e 防假 PASS（scenario1 显式 `-d assert.exception=1`，失败 assert 抛 `AssertionError` 中断脚本，防 grep 误判 PASS）
- Apache License 2.0

### 修复

- **scenario1 并发段 `wait` 死锁** — 无参 `wait` 等待所有后台作业（含 grpc_server/nginx 长期运行服务进程，不会自行退出）导致死锁；改为 `wait $CONC_PIDS` 只等 php/curl 子进程。

[0.1.0]: https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge/releases/tag/v0.1.0
