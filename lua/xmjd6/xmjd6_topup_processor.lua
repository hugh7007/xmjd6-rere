local M = {}

-- 模块级共享缓存：auto_fallback 与 topup_processor 都会 load()，
-- 只读一次文件、共用同一张表，避免每个组件实例各持一份
local cache = nil

local function get_script_dir()
    local source = debug.getinfo(1).source or ""
    return source:match("@?(.*/)")
end

local function is_ascii_text(text)
    if not text or text == "" then
        return false
    end
    for i = 1, #text do
        if text:byte(i) > 127 then
            return false
        end
    end
    return true
end

function M.load()
    if cache then return cache end
    local codes = {}
    local script_dir = get_script_dir()
    if not script_dir then
        return codes
    end

    local path = script_dir .. "../../xmjd6.zidingyi.dict.yaml"
    local file = io.open(path, "r")
    if not file then
        return codes
    end

    for line in file:lines() do
        local text, code = line:match("^([^\t]+)\t([a-z]+)")
        if text and code and is_ascii_text(text) then
            codes[code] = true
        end
    end

    file:close()
    cache = codes
    return codes
end

-- ════════════════════════════════════════════════════════════════
-- 以下为顶功 processor（原 xmjd6_topup_processor.lua 主体，2026-09-14 合并）：
--   protected_codes 表不再单独成文件；auto_fallback 改用 require(...).protected_codes。
-- ════════════════════════════════════════════════════════════════

-- 顶功处理器
local protected_codes = M
local candidate_order_ok, candidate_order_mod = pcall(require, "xmjd6.candidate_order")
local candidate_order_core = candidate_order_ok and candidate_order_mod and candidate_order_mod.core or nil

local function string2set(str)
    local t = {}
    if type(str) ~= "string" then return t end
    for i = 1, #str do
        t[str:sub(i,i)] = true
    end
    return t
end

local function topup(env)
    local ctx = env.engine.context
    if ctx:get_selected_candidate() then
        ctx:commit()
    elseif env.auto_clear then
        ctx:clear()
    end
end

local kNoop = 2

local function processor(key_event, env)
    if env.enable_sentence then
        return kNoop
    end

    if key_event:release() or key_event:ctrl() or key_event:alt() then
        return kNoop
    end

    local ch = key_event.keycode
    if ch < 0x20 or ch >= 0x7f then
        return kNoop
    end

    local context = env.engine.context
    local input = context.input
    if not input then return kNoop end

    -- 功能引导符开头的输入（=计算器/工具、\转字体、&Unicode）不参与顶功，
    -- 否则 =uuid、=floor(2) 这类字母输入会在第4码被强制上屏截断
    local lead = input:sub(1, 1)
    if lead == "=" or lead == "\\" or lead == "&" then
        return kNoop
    end

    local key = string.char(ch)
    if not env.alphabet[key] then
        return kNoop
    end

    local next_code = input .. key
    if env.protected_codes[next_code] then
        return kNoop
    end
    if candidate_order_ok and candidate_order_core
        and candidate_order_core.is_enabled(env)
        and candidate_order_core.has_code_prefix
        and candidate_order_core.has_code_prefix(next_code) then
        return kNoop
    end

    local first = #input > 0 and input:sub(1, 1) or key
    if env.topup_command and env.topup_set[first] then
        return kNoop
    end

    local input_len = utf8.len(input) or 0
    local prev = #input > 0 and input:sub(-1) or ""
    local is_topup = env.topup_set[key]
    local is_prev_topup = env.topup_set[prev]

    local min_len = context:get_option('danzi_mode')
        and env.topup_min_danzi
        or env.topup_min

    if is_prev_topup and not is_topup then
        topup(env)
    elseif not is_prev_topup and not is_topup and input_len >= min_len then
        topup(env)
    elseif input_len >= env.topup_max then
        topup(env)
    end

    return kNoop
end

local function init(env)
    local config = env.engine.schema.config
    env.enable_sentence = config:get_bool("translator/enable_sentence") or false
    env.topup_set = string2set(config:get_string("topup/topup_with") or "")
    env.alphabet = string2set(config:get_string("speller/alphabet") or "abcdefghijklmnopqrstuvwxyz")
    env.topup_min = math.max(1, config:get_int("topup/min_length") or 4)
    env.topup_min_danzi = math.max(1, config:get_int("topup/min_length_danzi") or env.topup_min)
    env.topup_max = math.max(env.topup_min, config:get_int("topup/max_length") or 6)
    env.auto_clear = config:get_bool("topup/auto_clear")
    env.topup_command = config:get_bool("topup/topup_command")
    env.protected_codes = protected_codes.load()
end

local function fini(env)
    env.enable_sentence = nil
    env.topup_set = nil
    env.alphabet = nil
    env.protected_codes = nil
end

return { init = init, func = processor, fini = fini,
    protected_codes = M }  -- [0914] 暴露给 auto_fallback（require(...).protected_codes）
