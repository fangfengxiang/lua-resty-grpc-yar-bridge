# 协议桥接决策

## bridge-1: protobuf field number 升序 → 位置参数

**状态：** 已采纳

**决策驱动因素：** gRPC 请求是 protobuf message（字段名 key），YAR 请求是位置参数数组。

**背景：** protobuf message 的字段有 name 和 number。YAR RPC 调用参数是位置数组 `[arg1, arg2, ...]`。

**思考与取舍：**
- 按 field number 升序提取值，构造位置数组
- 缓存排序后的字段名列表（`_sorted_fields_cache`），避免每请求排序
- `nil` 值跳过（未设置的字段不传参）

**业界参考：** grpc-gateway 的 JSON → protobuf 字段映射（但方向相反）。

## bridge-2: YAR retval → protobuf Response 的三路映射

**状态：** 已采纳

**决策驱动因素：** YAR 返回值类型不确定（标量/关联数组/索引数组），需映射到 protobuf message。

**背景：** PHP YAR Server 可返回任意值。gRPC Response 是固定结构的 protobuf message。

**思考与取舍：**
- 标量 → `{ result = retval }`（包装为单字段 message）
- 关联数组 → 直接作为 message table（字段名 key 对齐）
- 索引数组 → 映射到第一个 repeated 字段
- nil → 空消息（google.protobuf.Empty）

**业界参考：** grpc-gateway 的 `body` 映射规则（`body: "*"` 全量映射）。

## bridge-3: gRPC Method 名首字母小写 → YAR method

**状态：** 已采纳

**决策驱动因素：** gRPC Method 名是 PascalCase（如 `Add`），YAR method 名是 camelCase（如 `add`）。

**思考与取舍：**
- `method_to_yar(method)` — 首字母 `lower()`，其余不变
- 简单有效，覆盖 99% 场景
- 不处理 snake_case ↔ camelCase 转换（YAR 约定就是首字母小写）

**业界参考：** PHP Yar 的方法名约定（`$yar_client->add(...)`）。

## bridge-4: Client 缓存按 service 名

**状态：** 已采纳

**决策驱动因素：** persistent Client 跨请求复用，按 service 名缓存。

**背景：** 每个 gRPC Service 对应一个 YAR Server URL，Client 实例可跨请求复用。

**思考与取舍：**
- `_client_cache[service]` — 模块级 table
- `clear_cache()` 清空所有缓存（setup 重新加载时调用）
- Client 创建后设置 persistent + hooks，存入缓存

**业界参考：** lua-resty-yar 的 `get_client(uri, opts)` 弱值表缓存模式。

## bridge-5: hooks 注入集成可观测性

**状态：** 已采纳

**决策驱动因素：** 横切关注点（日志、指标）通过 hooks 注入，不侵入核心桥接逻辑。

**背景：** lua-yar 0.1.0 的 hooks 接口：`on_request(method, params)` / `on_response(method, retval, err_obj)`。

**思考与取舍：**
- `on_request` — 记录调用开始时间 + 触发用户 hooks
- `on_response` — 计算延迟 + 触发用户 hooks
- 用户 hooks 通过 `set_hooks` 注入，pcall 隔离；内置元数据收集恒开（供 `log_phase` 读取）

**业界参考：** grpc-gateway 的 middleware 注入模式；lua-yar `opts.hooks` 透传。

## bridge-6: service 名由 nginx named capture 提取，lua 只消费

**状态：** 已采纳

**决策驱动因素：** yar2grpc.handle 需要知道请求针对哪个 gRPC service；service 名承载在 URL path（PHP Yar client URL = `http://host/api/{Service}`）。path 解析规则是部署约定（前缀、段数由部署方定），不是协议契约。

**关联决策：** 与 grpc2yar 方向（init.lua `parse_grpc_path` 从 `/{Service}/{Method}` 解析）形成对比——gRPC HTTP/2 path 格式是协议契约（gRPC 规范规定），必须 lua 解析；yar2grpc 方向 path 格式是部署约定，应由 nginx 解析。

**背景：** 最初实现（v0.x）lua 内 `ngx.var.uri:match("^/[^/]+/([^/]+)")` 取 path 第二段作 service 名。问题：①解析规则硬编码在 lua，部署方改前缀（`/api/` → `/grpc-service/`）要改 lua 正则；②lua 承担 path 解析职责，与协议转换职责混杂；③取第二段只支持单段前缀，多段前缀（`/v1/grpc/X`）取错。

**思考与取舍：**
- 方案 A（lua 正则取末段 `"/([^/]+)$"`）：放开段数限制，但 path 解析仍耦合在 lua
- 方案 B（nginx named capture 提取变量，lua 读 `ngx.var.service_name`）：职责分离——nginx 声明式配置 path 规则，lua 只消费变量
- 方案 C（部署方注入解析函数）：过度灵活，复杂度不划算
- 选 B。nginx location 本就是声明式路由配置，path 解析是路由的一部分，由 nginx 承担天然；named capture 是 nginx 原生能力（PCRE named subpattern），声明式提取变量零运行时开销；lua 只读 `ngx.var.service_name`，协议转换层纯粹。部署方自由决定前缀规则，改 nginx 配置即可，lua 零改动。
- 名言对照："Separation of concerns" — Dijkstra, 1974："Concerns should be separated such that each addresses a single aspect." path 解析（路由关注点）与协议转换（桥接关注点）应分离。

**业界参考：** nginx named captures（PCRE `(?<name>...)` 语法，`ngx.var.<name>` 读取）是 nginx 原生能力；OpenResty 生态惯例——location 配置路由 + 变量提取，content_by_lua 做业务（如 lua-resty-openidc 用 location capture 传参）；Kong 的 router/business 分层同此思路。

**代码评价：** `handle()` 现只读 `ngx.var.service_name`，无 path 解析逻辑，职责单一；防御性兜底——变量缺失立即 400 报错（`service_name nginx variable not set`），不做 yar→pb；service 未注册 404，消息从 `not found in path` 修正为 `not registered: <name>`，语义更准。状态码用 `ngx.HTTP_BAD_REQUEST`/`ngx.HTTP_NOT_FOUND` 常量（非裸魔数），与同函数 `ngx.HTTP_INTERNAL_SERVER_ERROR` 用法一致。

**e2e 验证：** scenario1 覆盖三条路径——①正常路径（PHP yar client → add/subtract 值断言 `=== 42`/`=== 63`）；②404 路径（curl 打未注册 service `nonexistent.Service`，断言 HTTP 404 + body 含 `service not registered`）；③单 worker 交叉并发隔离（`worker_processes 1`，N 个 PHP 打正常 service + N 个 curl 打不存在 service 并发，断言 PHP 全 PASS + curl 全 404，证伪 `ngx.var.service_name` 跨请求读串——nginx 变量请求级 + handle 全 local，无模块级写状态）。防假 PASS：scenario1 显式 `-d assert.exception=1`，失败 assert 抛 `AssertionError` 中断脚本，不继续到 `echo PASS` 导致 grep 误判（PHP 默认 `assert.exception=0` 仅 Warning 不中断，值断言失效仍报 PASS）。

## bridge-7: grpc_converter 命名契约（隐式，待优化）

**状态：** 已采纳（隐式契约，setup 校验待优化为 P1）

**决策驱动因素：** 桥 setup 注册的 service/method 名与核心库 `grpc_converter.get_type_names` 拼接规则的边界契约，决定 pb 查找与 gRPC 路由是否命中。

**关联决策：** bridge-6（service 名由 nginx named capture 提取）、bridge-4（dispatch 委托核心库 forward）

**背景：** 核心库 `grpc_converter.get_type_names(service, method)` 拼接 `service .. "_" .. method .. "Request"` 作为 pb message 名传给 `pb.encode`/`pb.decode`（`forward.lua:29,35,52,61`）。桥 setup 注册 `_services[service_name] = { methods={...} }`，handle 读 `ngx.var.service_name` → 查 `_proxy_services` → 闭包捕获 service_name + grpc_method 调 `_dispatch` → `core_forward.encode_request(service, method, params)`。整条链路 service/method 命名必须与拼接规则 + proto message 命名约定 + gRPC path 标准对齐。

**决策（三条隐式契约）：**

1. **service 必须全限定**（`calculator.Calculator`，含 package 前缀）——拼接产出 `calculator.Calculator_AddRequest` = proto 全限定 message 名（`package.message_short`）→ pb 命中；grpc_transport URL `/grpc_backend/calculator.Calculator/Add` → Go gRPC path `/calculator.Calculator/Add`（gRPC 标准全限定）→ 路由命中。数学恒等：`pkg.S` + `_MethodRequest` = `pkg` + `.` + `S_MethodRequest`，当 message 短名 = `S_MethodRequest` 时成立。

2. **service key = nginx path 末段**（`ngx.var.service_name`）——handle `_proxy_services[ngx.var.service_name]` 查表命中；PHP client URL `/api/calculator.Calculator` → path 末段 `calculator.Calculator` = setup key。

3. **methods 必须用 gRPC Method 名**（`Add` 首字母大写）——setup 用 `method_to_yar(grpc_method)` 转 YAR 小写 `add` 做 proxy 子表 key（PHP client 调 `$client->add()`），闭包捕获原 gRPC 名 `Add` 传核心库 → 拼 `Calculator_AddRequest`（大写 A）→ proto message 命中。若误注册小写 `add`，拼 `Calculator_addRequest` → pb 查不到 → encode 失败。

**思考与取舍：** 当前三条契约是隐式的——核心库 `get_type_names` 无 service 全限定校验，桥 `setup` 无 method 名格式校验，proto message 命名约定只在 proto 注释里。适配成立完全依赖部署方正确配置 + proto 遵循 `{ServiceShort}_{Method}Request` 约定。

**业界参考：** gRPC 全限定 service 名（`package.Service`）标准；protobuf message 全限定名（`package.Message`）约定。

**代码评价：** 链路适配经三重验证——①拼接字符串逐字符相同（`calculator.Calculator_AddRequest` = proto 全限定 message 名）；②e2e json+msgpack 双 packager 全 PASS；③单 worker 交叉并发隔离验证通过。契约本身正确，问题在隐式。

**隐式契约的问题（后续优化）：**

1. **配置错误运行时才暴露**：部署方用短名 service（`Calculator` 缺 package）或小写 method（`add`）注册，setup 不报错，要到请求时 pb encode 失败（500）或 gRPC 路由 404 才发现，排障成本高。
2. **契约耦合 proto 命名约定**：拼接规则产出全限定 message 名，依赖 proto message 短名恰好 = `{ServiceShort}_{Method}Request`。若 proto 用别的命名（如 `{Service}_{Method}Input`），静默断裂。
3. **跨 repo 契约无单一来源**：命名契约横跨 bridge（setup 注册）+ 核心库（grpc_converter 拼接）+ proto（message 命名）三处，文档分散，无中心 ADR，易腐化。本 ADR 是首个集中记录。
4. **无校验**：核心库 `get_type_names` 不校验 service 含 `.`（全限定标志），桥 `setup` 不校验 method 首字母大写，违反契约不 fail fast。

**后续优化方向（P1，后续 issue 跟进）：**

- **setup 时校验**：`setup()` 对每个 service key 检查含 `.`（全限定），对每个 method 检查首字母大写，违反即 `error()`（fail fast，部署即暴露而非运行时）
- **get_type_names 校验**：service 不含 `.` 时 err（提示可能非全限定）
- **proto lint**：gen 阶段校验 message 短名 = `{ServiceShort}_{Method}Request`，违反报错
- **契约文档移至核心库**：grpc_converter 在 lua-yar-grpc，命名契约 ADR 应最终落在核心库 docs（核心库目前无 docs/，需新建）
