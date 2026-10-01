std = "ngx_lua"

cache = true

ignore = {"212/self", "212/args", "212/loop", "212/unused"}

max_line_length = 120

-- ngx_lua std 未包含的 ngx 字段补充声明
globals = {
    "ngx.HTTP_METHOD_NOT_ALLOWED",
}
