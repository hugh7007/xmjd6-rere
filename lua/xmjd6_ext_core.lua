-- 天行键低频扩展核心调度入口
-- 按输入类型懒加载日期时间核心或计算器核心，避免一次加载全部低频逻辑。
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-05-29

local M = {}

local string_sub = string.sub
local tonumber = tonumber
local format = string.format
local match = string.match
local sub = string.sub
local floor = math.floor
local random = math.random
local randomseed = math.randomseed
local registry = require("common.xmjd6_cache_registry")
local utf8_codes = utf8.codes
local utf8_char = utf8.char

local time_core
local calculator_core
local module_prefix
local history_slots = {}
local history_size = 3
local seeded = false
local password_len_min = 8
local password_len_max = 64
local default_password_len = 16
local alpha_num_chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local symbol_chars = "!@#$%^&*()-_=+[]{}:,.?/"
local strong_chars = alpha_num_chars .. symbol_chars

local function is_cjk_codepoint(code)
    return (code >= 0x3400 and code <= 0x4DBF) or
           (code >= 0x4E00 and code <= 0x9FFF) or
           (code >= 0xF900 and code <= 0xFAFF)
end

local function normalize_history_text(text)
    local has_cjk = false
    for _, code in utf8_codes(text) do
        if is_cjk_codepoint(code) then
            has_cjk = true
            break
        end
    end

    if not has_cjk then
        if match(text, "[%w]") then return text end
        return nil
    end

    local parts = {}
    for _, code in utf8_codes(text) do
        if is_cjk_codepoint(code) or
           (code >= 48 and code <= 57) or
           (code >= 65 and code <= 90) or
           (code >= 97 and code <= 122) then
            parts[#parts + 1] = utf8_char(code)
        end
    end
    return table.concat(parts)
end

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

local function config_int(env, path, default)
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    local value = config and config:get_int(path)
    return value or default
end

local function history_put(text)
    if type(text) ~= "string" or text == "" then return false end
    for i = history_size, 2, -1 do
        history_slots[i] = history_slots[i - 1]
    end
    history_slots[1] = text
    return true
end

function M.history_set_size(size)
    size = tonumber(size) or 3
    if size < 1 then size = 1 end
    if size > 9 then size = 9 end
    history_size = size
    for i = history_size + 1, #history_slots do
        history_slots[i] = nil
    end
end

function M.history_record(text, source_input)
    if type(text) ~= "string" or text == "" then return false end
    if source_input == "=mem" or source_input == "=mem!" then return false end
    if type(source_input) == "string" and string_sub(source_input, 1, 1) == "i" then return false end
    text = normalize_history_text(text)
    if type(text) ~= "string" or text == "" then return false end
    return history_put(text)
end

local function history_label()
    return "(历史)"
end

function M.history_func(input, seg, env)
    if type(input) ~= "string" or string_sub(input, 1, 1) ~= "i" then return false end
    M.history_set_size(config_int(env, get_module_prefix(env) .. "/history_size", 3))
    local yielded = 0
    for i = 1, history_size do
        local text = history_slots[i]
        if text and text ~= "" then
            yielded = yielded + 1
            local cand = Candidate("history", seg.start, seg._end, text, history_label())
            cand.quality = 10000 - i
            yield(cand)
        end
    end
    return yielded > 0
end

local function seed_random()
    if seeded then return end
    local t = os.time()
    local mem = floor((collectgarbage("count") or 0) * 1000)
    randomseed(t + mem)
    for _ = 1, 8 do random() end
    seeded = true
end

local function rand_int(min_value, max_value)
    seed_random()
    return random(min_value, max_value)
end

local function rand_hex(count)
    local parts = {}
    for i = 1, count do
        parts[i] = format("%x", rand_int(0, 15))
    end
    return table.concat(parts)
end

local function uuid_v4()
    local variants = {"8", "9", "a", "b"}
    return rand_hex(8) .. "-" .. rand_hex(4) .. "-4" .. rand_hex(3) .. "-" .. variants[rand_int(1, 4)] .. rand_hex(3) .. "-" .. rand_hex(12)
end

local function random_password(len, chars)
    local parts = {}
    for i = 1, len do
        local index = rand_int(1, #chars)
        parts[i] = sub(chars, index, index)
    end
    return table.concat(parts)
end

local function tip(text)
    if not text or text == "" then return "" end
    return "(" .. text .. ")"
end

local function password_tip(text)
    if not text or text == "" then return "" end
    return "  " .. tip(text)
end

local function timestamp_comment(seconds)
    local now = os.time()
    if not now then return "" end
    local diff = seconds - now
    local abs_days = floor(math.abs(diff) / 86400)
    if abs_days == 0 then
        return diff >= 0 and tip("未来24小时内") or tip("过去24小时内")
    end
    return diff >= 0 and tip(abs_days .. "天后") or tip(abs_days .. "天前")
end

local function is_calendar_query(input)
    local n = input:match("^=(%d+)$")
    if not n or not (n:match("^19%d%d") or n:match("^20%d%d") or n:match("^21%d%d")) then
        return false
    end
    if #n > 8 then
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

local function tools_is_input(input)
    if input == "=uuid" or input == "=mem" or input == "=mem!" then return true end
    if match(input or "", "^=pw%d*$") then return true end
    if match(input or "", "^=%d+$") then return true end
    return false
end

local function pure_number_tools(input, seg, env)
    local n = match(input, "^=(%d+)$")
    if not n then return false end
    local core = load_calculator_core(env)
    if core.money_text then
        yield(Candidate("number", seg.start, seg._end, core.money_text(n), tip("金额")))
    end
    if #n == 10 or #n == 13 then
        local seconds = #n == 13 and tonumber(sub(n, 1, 10)) or tonumber(n)
        local millis = #n == 13 and (tonumber(sub(n, 11, 13)) or 0) or 0
        if seconds then
            local ok, t = pcall(os.date, "*t", seconds)
            if ok and t then
                local text = format("%04d-%02d-%02d %02d:%02d:%02d.%03d", t.year, t.month, t.day, t.hour, t.min, t.sec, millis)
                yield(Candidate("time", seg.start, seg._end, text, timestamp_comment(seconds)))
            end
        end
    end
    if is_calendar_query(input) then
        M.time_func(input, seg, env)
    end
    return true
end

local function tools_func(input, seg, env)
    if input == "=uuid" then
        local lower = uuid_v4()
        local upper = string.upper(lower)
        yield(Candidate("uuid", seg.start, seg._end, lower, tip("UUID v4 小写")))
        yield(Candidate("uuid", seg.start, seg._end, upper, tip("UUID v4 大写")))
        return true
    end
    if input == "=mem" then
        local kb = collectgarbage("count") or 0
        local kb_text = format("Lua %.1f KB", kb)
        local mb_text = format("Lua %.2f MB", kb / 1024)
        local count_text = tostring(#registry.names())
        yield(Candidate("memory", seg.start, seg._end, kb_text, tip("Lua 内存 KB")))
        yield(Candidate("memory", seg.start, seg._end, mb_text, tip("Lua 内存 MB")))
        yield(Candidate("memory", seg.start, seg._end, count_text, tip("已注册清理器")))
        return true
    end
    if input == "=mem!" then
        local before = collectgarbage("count") or 0
        local cleared, failed = registry.clear_all()
        local after = collectgarbage("count") or 0
        local comment = failed > 0 and (cleared .. "项已清理，" .. failed .. "项失败") or (cleared .. "项已清理")
        local range_text = format("Lua %.1f KB -> %.1f KB", before, after)
        local after_text = format("Lua %.2f MB", after / 1024)
        yield(Candidate("memory", seg.start, seg._end, range_text, tip(comment)))
        yield(Candidate("memory", seg.start, seg._end, after_text, tip("清理后内存")))
        return true
    end
    local len_text = match(input or "", "^=pw(%d*)$")
    if len_text ~= nil then
        local len = len_text ~= "" and tonumber(len_text) or default_password_len
        if not len or len < password_len_min or len > password_len_max then
            yield(Candidate("password", seg.start, seg._end, "密码长度需为 8~64", tip("随机密码")))
            return true
        end
        local strong = random_password(len, strong_chars)
        local alnum = random_password(len, alpha_num_chars)
        yield(Candidate("password", seg.start, seg._end, strong, password_tip(len .. "·含符号")))
        yield(Candidate("password", seg.start, seg._end, alnum, password_tip(len .. "·字母数字")))
        return true
    end
    return pure_number_tools(input, seg, env)
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

function M.jisuanqi_func(input, seg, env)
    if tools_is_input(input) then
        if tools_func(input, seg, env) then
            return
        end
    end
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

function M.tools_fini(env)
    seeded = false
end

function M.func(input, seg, env)
    if not input or input == "" then
        return
    end

    M.history_set_size(config_int(env, get_module_prefix(env) .. "/history_size", 3))

    if string_sub(input, 1, 1) == "=" then
        M.jisuanqi_func(input, seg, env)
        return
    end

    if is_calendar_input(input) then
        M.time_func(input, seg, env)
    end
end

function M.fini(env)
    M.tools_fini(env)
    M.jisuanqi_fini(env)
    M.time_fini(env)
end

return M
