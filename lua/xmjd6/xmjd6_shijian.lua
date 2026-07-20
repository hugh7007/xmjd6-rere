-- xmjd6_shijian.lua
-- 时间/日期/农历/节气 translator 的懒加载入口。
-- 真正的实现（91KB 天文历法计算 + 数据表）在 shijian_impl.lua，
-- 只有输入命中触发码时才 require；iOS 清内存 sentinel（见 dict_search_trigger.lua）
-- 会把它从 package.loaded 卸载，下次触发时重新加载。

local mem_cleaner = require("xmjd6.mem_cleaner")

local IMPL_MODULE = "xmjd6.shijian_impl"

-- 精确触发码（与 shijian_impl.lua 内 translator 的分支一一对应）
local TRIGGERS = {
    rq = true,       -- 日期
    ej = true,       -- 时间
    xq = true,       -- 星期
    nl = true,       -- 农历
    jq = true,       -- 节气
    ["sjx/"] = true, -- 生日/节日倒计时
}

-- 模块级注册：sentinel 到达时卸载 impl，释放其全部函数与天文数据表
mem_cleaner.register(function()
    package.loaded[IMPL_MODULE] = nil
end)

local function translator(input, seg, env)
    local hit = TRIGGERS[input]
    if not hit and string.sub(input, 1, 1) == "=" then
        -- 形如 =19xxxx / =20xxxx 的日历查询（判断与 impl 内保持一致）
        local n = string.sub(input, 2)
        hit = tonumber(n) ~= nil
            and (string.match(n, "^19%d%d+$") ~= nil or string.match(n, "^20%d%d+$") ~= nil)
    end
    if not hit then return end

    local ok, impl = pcall(require, IMPL_MODULE)
    if ok and impl then
        impl(input, seg, env)
    end
end

return translator
