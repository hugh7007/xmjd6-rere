-- 天行键低频扩展核心调度入口
-- 按输入类型懒加载日期时间核心或计算器核心，避免一次加载全部低频逻辑。
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-29

local M = {}

local string_sub = string.sub
local tonumber = tonumber

local time_core
local calculator_core
local module_prefix

local function get_module_prefix(env)
    if module_prefix then
        return module_prefix
    end
    local source = debug and debug.getinfo and debug.getinfo(1, "S")
    local source_path = source and source.source or ""
    local normalized = source_path:gsub("\\", "/")
    local name = normalized:match("([^/]+)_ext_core%.lua$")
    if not name and env and env.engine and env.engine.schema then
        name = env.engine.schema.schema_id
    end
    module_prefix = (name and name ~= "" and name) or "xmjd6"
    return module_prefix
end

local function require_core(suffix, env)
    return require(get_module_prefix(env) .. suffix)
end

local function load_time_core(env)
    if not time_core then
        time_core = require_core("_time_core", env)
    end
    return time_core
end

local function load_calculator_core(env)
    if not calculator_core then
        calculator_core = require_core("_calculator_core", env)
    end
    return calculator_core
end

local function is_calendar_query(input)
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

local function is_calendar_input(input)
    return input == "rq"
        or input == "nl"
        or input == "nylk"
        or input == "jq"
        or input == "jdqk"
        or input == "eo"
        or input == "jkdm"
        or input == "xq"
        or input == "xgqk"
        or is_calendar_query(input)
end

function M.time_func(input, seg, env)
    local core = load_time_core(env)
    if core.func then
        core.func(input, seg, env)
    end
end

function M.time_fini(env)
    if time_core and time_core.fini then
        time_core.fini(env)
    end
end

function M.get_jq_data()
    local core = load_time_core()
    if core.get_jq_data then
        return core.get_jq_data()
    end
    return nil
end

function M.jisuanqi_func(input, seg, env)
    if input and is_calendar_query(input) then
        M.time_func(input, seg, env)
        return
    end
    local core = load_calculator_core(env)
    if core.func then
        core.func(input, seg, env)
    end
end

function M.jisuanqi_fini(env)
    if calculator_core and calculator_core.fini then
        calculator_core.fini(env)
    end
end

function M.func(input, seg, env)
    if not input or input == "" then
        return
    end

    if string_sub(input, 1, 1) == "=" then
        M.jisuanqi_func(input, seg, env)
        return
    end

    if is_calendar_input(input) then
        M.time_func(input, seg, env)
    end
end

function M.fini(env)
    M.jisuanqi_fini(env)
    M.time_fini(env)
end

return M
