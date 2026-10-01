<?php
/**
 * PHP Yar Client — 场景1客户端（YAR → gRPC 方向）
 *
 * 向 OpenResty 发送 YAR 协议请求，OpenResty 通过 yar2grpc
 * 转换为 gRPC 调用，转发到 Go gRPC Server。
 *
 * 依赖：php-yar 扩展（pecl install yar）
 * 用法：php client.php
 *       php -d yar.packager=msgpack client.php  （覆盖打包器）
 */

// 从环境变量读取打包器，默认 json（避免 PHP 默认的 php serialize 格式，
// lua-yar 不支持 php serialize，只能解析 json/msgpack）
$packager = getenv("YAR_PACKAGER") ?: "json";

// e2e 端口由 run_e2e.sh 集中定义并 export（默认 1985），独立运行回退默认值
$port = getenv("E2E_PORT_YAR2GRPC") ?: "1985";
$client = new Yar_Client("http://127.0.0.1:{$port}/api/calculator.Calculator");
$client->setOpt(YAR_OPT_PACKAGER, $packager);

// 场景1测试：通过 OpenResty 反向桥接调用 Go gRPC 后端
$result_add = $client->add(15, 27);
echo "add(15, 27) = " . $result_add . "\n";
assert($result_add === 42, "Expected 42, got {$result_add}");

$result_sub = $client->subtract(100, 37);
echo "subtract(100, 37) = " . $result_sub . "\n";
assert($result_sub === 63, "Expected 63, got {$result_sub}");

echo "Scenario 1 (PHP Yar → OpenResty → Go gRPC): PASS\n";
