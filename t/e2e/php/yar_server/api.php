<?php
/**
 * PHP Yar Server — 场景2后端（gRPC → YAR 方向）
 *
 * OpenResty 收到 gRPC 请求后，通过 grpc2yar.lua 转换为 YAR 调用，
 * 请求到达此 PHP Yar Server，返回结果后原路转回 gRPC。
 *
 * 依赖：php-yar 扩展（pecl install yar）
 * 启动：php -d yar.packager=json -S 127.0.0.1:8888 api.php
 *       （yar.packager 是 PHP_INI_SYSTEM 级别，必须用 -d 参数设置，
 *        ini_set 无法修改；默认 php serialize 格式 lua-yar 无法解析）
 */

class Calculator
{
    /**
     * @param int $a
     * @param int $b
     * @return int
     */
    public function add($a, $b)
    {
        return $a + $b;
    }

    /**
     * @param int $a
     * @param int $b
     * @return int
     */
    public function subtract($a, $b)
    {
        return $a - $b;
    }
}

$server = new Yar_Server(new Calculator());
$server->handle();
