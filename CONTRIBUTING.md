# 贡献指南

感谢你对 `lua-resty-yar-grpc-bridge` 的关注！欢迎以任何形式参与贡献。

## 行为准则

参与本项目即表示你同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) 中的行为准则。请始终保持尊重和友善。

## 如何贡献

### 报告 Bug

1. 在 [Issues](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge/issues) 中搜索是否已有相同问题
2. 若不存在，新建 Issue 并包含以下信息：
   - OpenResty 版本、操作系统
   - 复现步骤（nginx 配置、gRPC 客户端调用代码）
   - 期望行为与实际行为
   - 错误日志（`error.log` 相关行）

### 提交功能建议

1. 先在 [Issues](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge/issues) 中发起讨论，说明使用场景和设计思路
2. 获得维护者认可后，按下方流程提交 Pull Request

### 提交 Pull Request

1. Fork 本仓库
2. 创建特性分支：

   ```bash
   git checkout -b feature/my-feature
   ```

3. 编写代码，确保：
   - 通过 `make lint`（luacheck 代码检查）
   - 通过 `make test`（test-nginx 测试套件）
   - 新增功能附带对应测试用例
4. 提交信息遵循 [约定式提交](https://www.conventionalcommits.org/zh-hans/v1.0.0/)：

   ```
   feat: 支持 gRPC 压缩标志
   fix: 修复 YAR 超时未正确映射 gRPC 状态码的问题
   docs: 补充 CHANGELOG
   refactor: 提取帧编解码为独立模块
   test: 增加 map_response 边界用例
   chore: 升级 luacheck 配置
   ```

5. Push 并发起 Pull Request，描述变更内容和动机

## 开发环境

### 前置要求

- [OpenResty](https://openresty.org) >= 1.19.3.1
- [Perl](https://www.perl.org/)（test-nginx 测试框架依赖）
- [luacheck](https://github.com/mpeterv/luacheck)（代码检查）
- [lua-yar](https://github.com/fangfengxiang/lua-yar)
- [lua-protobuf](https://github.com/starwing/lua-protobuf)

### 克隆与安装依赖

```bash
git clone https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge.git
cd lua-resty-yar-grpc-bridge

# 安装依赖
luarocks install lua-yar
luarocks install lua-protobuf

# 安装 test-nginx 测试框架
git clone https://github.com/openresty/test-nginx.git ../test-nginx
```

### 运行测试

```bash
make test
```

### 代码检查

```bash
make lint
```

## 代码风格

- 使用 4 空格缩进
- 模块级局部变量对齐（`local pb = require("pb")`）
- 函数注释使用 LuaDoc 风格（`---` 开头 + `@param` / `@return`）
- 避免全局变量，所有导出通过 `_M` 表

## 许可证

提交的代码将按 [Apache License 2.0](LICENSE) 许可发布。
