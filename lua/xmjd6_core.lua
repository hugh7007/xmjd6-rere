-- 天行键低频扩展轻入口
-- 首次触发时加载 txjx_ext_core 并常驻，天文大表按需加载/释放。
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-09

local string_sub = string.sub

local core

local function is_calendar_input(input)
    local n = input:match("^=(%d+)$")
    if not n or not (n:match("^19%d%d") or n:match("^20%d%d") or n:match("^21%d%d")) then
        return false
    end
    if #n >= 6 then
        local month = tonumber(string_sub(n, 5, 6))
        if not month or month < 1 or month > 12 then
            return false
        end
    end
    if #n >= 8 then
        local day = tonumber(string_sub(n, 7, 8))
        if not day or day < 1 or day > 31 then
            return false
        end
    end
    return true
end

local function is_time_input(input)
    return input == "rq"
        or input == "nl"
        or input == "nylk"
        or input == "jq"
        or input == "jdqk"
        or input == "eo"
        or input == "jkdm"
        or input == "xq"
        or input == "xgqk"
        or is_calendar_input(input)
end

local function is_calc_input(input, env)
    if input == "=" or string_sub(input, 1, 1) ~= "=" then
        return false
    end
    local ctx = env and env.engine and env.engine.context
    return not (ctx and ctx.get_option and not ctx:get_option("jisuanqi"))
end

local function translator(input, seg, env)
    if not input or input == "" then
        return
    end

    if string_sub(input, 1, 1) == "=" then
        local ctx = env and env.engine and env.engine.context
        if ctx and ctx.get_option and not ctx:get_option("jisuanqi") then
            return
        end
        core = core or require("xmjd6_ext_core")
        if core.jisuanqi_func then
            core.jisuanqi_func(input, seg, env)
        end
        return
    end

    if not is_time_input(input) and not is_calc_input(input, env) then
        return
    end

    core = core or require("xmjd6_ext_core")
    core.func(input, seg, env)
end

local function fini(env)
    if core and core.fini then
        core.fini(env)
    end
end

return { func = translator, fini = fini }
