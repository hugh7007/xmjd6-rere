-- 天行键计算器输入、标点与候选快捷选择
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-10

local string_byte = string.byte
local string_find = string.find
local string_sub = string.sub
local type = type
local config_util = require("common.xmjd6_config")
local key_event_util = require("xmjd6_key_event")
local commit_guard = require("xmjd6_commit_guard")
local ascii_input = require("xmjd6_ascii_input")

local M = {}
local kAccepted = 1
local kNoop = 2
local CHAR_CACHE = key_event_util.char_cache
local APOSTROPHE = string.char(39)
local LEFT_SINGLE_QUOTE = utf8.char(0x2018)
local LEFT_DOUBLE_QUOTE = utf8.char(0x201C)

local SYMBOL_CN = {
    slash = { plain = "/", shift = "？" }, backslash = { plain = "\\", shift = "·" },
    minus = { plain = "-", shift = "——" }, equal = { plain = "＝", shift = "+" },
    semicolon = { plain = "；", shift = "：" }, apostrophe = { plain = LEFT_SINGLE_QUOTE, shift = LEFT_DOUBLE_QUOTE },
    bracketleft = { plain = "【", shift = "{" }, bracketright = { plain = "】", shift = "}" },
    comma = { plain = "，", shift = "《" }, period = { plain = "。", shift = "》" },
    grave = { plain = "·", shift = "～" },
}
local SMART_OFF = { semicolon = { plain = ";", shift = "：" }, apostrophe = { plain = APOSTROPHE, shift = LEFT_DOUBLE_QUOTE } }
local CALCULATOR_OFF = { equal = { plain = "=", shift = "+" } }
local CALC_KEY = {
    space = " ", minus = "-", equal = "=", slash = "/", backslash = "\\",
    comma = ",", period = ".", bracketleft = "[", bracketright = "]", grave = "`",
}
local CALC_SHIFT_KEY = {
    minus = "_", equal = "+", slash = "?", backslash = "|", semicolon = ":",
    apostrophe = "\"", comma = "<", period = ">", bracketleft = "{",
    bracketright = "}", grave = "~",
}
local CALC_SHIFT_DIGIT = {
    [48] = ")", [49] = "!", [51] = "#", [52] = "$", [53] = "%",
    [54] = "^", [55] = "&", [56] = "*", [57] = "(",
}
local CALC_SYMBOL_SET = config_util.s2set("+-*/%^#=~<>(){}[].,:$\\|&\"_?! ")

local function commit_symbol(map, key_name, shift, engine, ctx)
    local config = map[key_name]
    if not config then return false end
    local symbol = shift and config.shift or config.plain
    if not symbol then return false end
    if ctx:is_composing() then ctx:commit() end
    engine:commit_text(symbol)
    return true
end

local function calc_char(key_name, shift, keycode, clean_key, repr)
    if shift then
        local shifted = CALC_SHIFT_DIGIT[keycode]
        if shifted then return shifted end
    elseif keycode >= 48 and keycode <= 57 then
        return CHAR_CACHE[keycode]
    end
    local symbol = shift and CALC_SHIFT_KEY[key_name] or CALC_KEY[key_name]
    if symbol then return symbol end
    if keycode >= 65 and keycode <= 90 then return string.char(keycode + 32) end
    if keycode >= 97 and keycode <= 122 then return CHAR_CACHE[keycode] end
    if type(clean_key) == "string" and #clean_key == 1 then
        local byte = string_byte(clean_key, 1)
        if byte >= 65 and byte <= 90 then return CHAR_CACHE[byte + 32] end
        if byte >= 97 and byte <= 122 then return clean_key end
    end
    if type(repr) == "string" and #repr == 1 then
        local byte = string_byte(repr, 1)
        if byte >= 65 and byte <= 90 then return string.char(byte + 32) end
        if byte >= 97 and byte <= 122 then return repr end
    end
    if keycode >= 32 and keycode <= 126 then
        local char = CHAR_CACHE[keycode]
        if CALC_SYMBOL_SET[char] then return char end
    end
    if type(repr) == "string" and #repr == 1 and CALC_SYMBOL_SET[repr] then return repr end
    return nil
end

local function is_calc_context(ctx, opts)
    return opts and opts.jisuanqi and ctx and type(ctx.input) == "string" and string_sub(ctx.input, 1, 1) == "="
end

local function clear_transition(env, ctx)
    env._shift_inline_ascii = nil
    commit_guard.clear_space(env)
    ascii_input.clear_append(env, ctx)
end

function M.process(key_event, env, key_name, shift, clean_key, opts)
    if key_event:alt() or key_event:super() then return kNoop end
    local ctx = env.engine.context
    local keycode = key_event.keycode
    local repr = key_event:repr()
    if key_name == "grave" and not shift and not key_event:ctrl() then
        if key_event:release() then return kAccepted end
        ctx:push_input("`")
        return kAccepted
    end
    if not key_event:release() and not shift and ctx.input == "-" and keycode >= 48 and keycode <= 57 then
        ctx:commit()
        env.engine:commit_text(CHAR_CACHE[keycode])
        return kAccepted
    end
    if not key_event:release() and is_calc_context(ctx, opts)
        and not key_event_util.is_space(keycode, clean_key, repr) then
        local char = calc_char(key_name, shift, keycode, clean_key, repr)
        if char then
            if char == "=" and (ctx.input or "") == "=" then
                if env._calc_equal_allow_next then
                    ctx:push_input(char)
                    env._calc_equal_allow_next = nil
                else
                    env._calc_equal_allow_next = false
                end
                return kAccepted
            end
            env._calc_equal_allow_next = nil
            ctx:push_input(char)
            return kAccepted
        end
    end
    local direct_symbols_off = not opts.direct_symbols
    if key_event:release() then
        if key_name == "equal" then env._calc_equal_allow_next = (ctx.input or "") == "=" end
        if key_name and env._sw == key_name then env._sw = nil; return kAccepted end
        if key_name and env._dc == key_name then env._dc = nil; return kAccepted end
        if direct_symbols_off then env._dc = nil end
        return kNoop
    end
    env._dc = nil
    if key_name == "period" and not shift and not ctx:is_composing() then
        if env._standalone_period_after_digit then
            env._standalone_period_after_digit = nil
            clear_transition(env, ctx)
            env.engine:commit_text(".")
            return kAccepted
        end
        clear_transition(env, ctx)
        env.engine:commit_text("。")
        return kAccepted
    end
    if key_name == "period" and not shift and ctx:is_composing() then
        clear_transition(env, ctx)
        ctx:commit()
        env.engine:commit_text("。")
        env._dc = key_name
        return kAccepted
    end
    if env._tu_streaming and not shift and (key_name == "semicolon" or key_name == "apostrophe") then return kNoop end
    if not env._tu_streaming and not opts.smarttwo and not direct_symbols_off
        and not shift and key_name == "semicolon" then
        local input = ctx.input
        if input ~= "" and not string_find(input, ";", 1, true)
            and ctx:has_menu() and commit_guard.selected_is_non_completion(ctx) then
            commit_guard.commit_selected_non_completion(ctx)
            ctx:push_input(";")
            env._sw = key_name
            return kAccepted
        end
    end
    if ctx:has_menu() and opts.smarttwo and (key_name == "semicolon" or key_name == "apostrophe") and not shift then
        if env._tu_streaming then return kNoop end
        local comp = ctx.composition:back()
        if comp then
            local index = key_name == "semicolon" and 1 or 2
            if commit_guard.commit_menu_index(ctx, env.engine, index) then return kAccepted end
            if not commit_guard.selected_candidate(ctx) then
                if #ctx.input > 1 then ctx:commit(); return kAccepted end
            elseif commit_guard.commit_selected_non_completion(ctx) then
                return kAccepted
            end
        end
    end
    if direct_symbols_off then
        if key_name == "period" and not shift and not ctx:is_composing() then return kNoop end
        if not (key_name == "equal" and not shift and opts.jisuanqi) then
            if commit_symbol(SYMBOL_CN, key_name, shift, env.engine, ctx) then
                commit_guard.guard_shift_symbol_release(env, shift)
                env._dc = key_name
                return kAccepted
            end
        end
        if not env._tu_streaming and ctx:has_menu()
            and not key_event_util.is_alpha(env, key_name, clean_key, keycode) then
            local segment = ctx.composition:back()
            if segment and segment.menu:get_candidate_at(0) and not segment.menu:get_candidate_at(1) then
                local input = ctx.input
                if input ~= ";" and input ~= "；" and commit_guard.commit_selected_non_completion(ctx) then return kAccepted end
            end
        end
    end
    if not opts.jisuanqi then
        if (key_name == "equal" or key_name == "minus") and ctx:has_menu() and not shift then return kNoop end
        if commit_symbol(CALCULATOR_OFF, key_name, shift, env.engine, ctx) then
            commit_guard.guard_shift_symbol_release(env, shift)
            return kAccepted
        end
    end
    if not opts.smarttwo then
        if key_name == "semicolon" and not shift then return kNoop end
        if key_name == "apostrophe" then return kNoop end
        if commit_symbol(SMART_OFF, key_name, shift, env.engine, ctx) then
            commit_guard.guard_shift_symbol_release(env, shift)
            return kAccepted
        end
    end
    return kNoop
end

return M
