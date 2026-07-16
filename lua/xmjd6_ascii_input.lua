-- 天行键 ASCII、Caps 与追加候选输入
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-10

local string_byte = string.byte
local type = type
local state = require("common.xmjd6_state")
local key_event_util = require("xmjd6_key_event")
local commit_guard = require("xmjd6_commit_guard")

local M = {}
local kAccepted = 1
local kNoop = 2
local CHAR_CACHE = key_event_util.char_cache

local CALC_KEY = {
    space = " ", minus = "-", equal = "=", slash = "/", backslash = "\\",
    comma = ",", period = ".", bracketleft = "[", bracketright = "]", grave = "`",
}
local CALC_SHIFT_KEY = {
    minus = "_", equal = "+", slash = "?", backslash = "|", semicolon = ":",
    apostrophe = "\"", comma = "<", period = ">", bracketleft = "{",
    bracketright = "}", grave = "~",
}

function M.clear_append(env, ctx)
    state.clear_append(env, ctx)
end

function M.set_append(env, ctx, suffix)
    return state.set_append(env, ctx, suffix)
end

function M.get_append_suffix(env, ctx)
    return state.get_append_suffix(env, ctx)
end

function M.append_suffix(env, ctx, suffix)
    return state.append_suffix(env, ctx, suffix)
end

function M.pop_append_suffix(env, ctx)
    return state.pop_append_suffix(env, ctx)
end

function M.commit_append(env, ctx, engine)
    return state.commit_append(env, ctx, engine)
end

function M.append_char(key_name, shift, caps_on, keycode, clean_key, repr)
    if keycode >= 65 and keycode <= 90 then return CHAR_CACHE[keycode] end
    if (shift or caps_on) and keycode >= 97 and keycode <= 122 then return CHAR_CACHE[keycode - 32] end
    if keycode >= 97 and keycode <= 122 then return CHAR_CACHE[keycode] end
    if keycode >= 48 and keycode <= 57 then return CHAR_CACHE[keycode] end
    if type(clean_key) == "string" and #clean_key == 1 then
        local byte = string_byte(clean_key, 1)
        if (shift or caps_on) and byte >= 97 and byte <= 122 then return CHAR_CACHE[byte - 32] end
        if (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or (byte >= 48 and byte <= 57) then
            return clean_key
        end
    end
    if type(repr) == "string" and #repr == 1 then
        local byte = string_byte(repr, 1)
        if (shift or caps_on) and byte >= 97 and byte <= 122 then return CHAR_CACHE[byte - 32] end
        if (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or (byte >= 48 and byte <= 57) then
            return repr
        end
    end
    return nil
end

function M.symbol_char(key_name, shift, caps_on)
    if not (shift or caps_on) or not key_name or key_name == "" then return nil end
    return shift and CALC_SHIFT_KEY[key_name] or CALC_KEY[key_name]
end

function M.process_front(key_event, env, key_name, shift, clean_key, repr)
    local ctx = env.engine.context
    local keycode = key_event.keycode
    if ctx:is_composing() and M.get_append_suffix(env, ctx)
        and key_event_util.is_append_delete(clean_key, repr, keycode) then
        if key_event:release() then return kAccepted end
        if M.pop_append_suffix(env, ctx) then return kAccepted end
    end
    if key_event_util.is_topup_cancel(clean_key, repr, keycode) then
        commit_guard.clear_space(env)
        M.clear_append(env, ctx)
        return kNoop
    end
    if key_event_util.is_enter(clean_key, repr, keycode) then
        commit_guard.clear_space(env)
        if key_event:release() then return kAccepted end
        if M.commit_append(env, ctx, env.engine) then return kAccepted end
        M.clear_append(env, ctx)
        local input = ctx.input
        if ctx:is_composing() and input and input ~= "" then
            ctx:clear()
            env.engine:commit_text(input)
            return kAccepted
        end
        return kNoop
    end
    if key_event_util.is_shift(clean_key, repr, keycode) then
        commit_guard.clear_space(env)
        if key_event:release() and env._shift_symbol_release_guard then
            env._shift_symbol_release_guard = nil
            return kAccepted
        end
        if not key_event:release() then env._shift_symbol_release_guard = nil end
        return kNoop
    end
    if key_event_util.is_caps(clean_key, repr, keycode) then
        commit_guard.clear_space(env)
        if key_event_util.repr_has_lock(repr) then
            env._caps_lock_on = true
        elseif key_event:release() then
            env._caps_lock_on = false
        end
        if env._caps_blocked then
            if key_event:release() then env._caps_blocked = nil end
            if ctx:is_composing() then return kAccepted end
            env._caps_blocked = nil
            return kNoop
        end
        if ctx:is_composing() then
            env._caps_blocked = true
            return kAccepted
        end
        return kNoop
    end

    local ascii_mode = ctx:get_option("ascii_mode")
    local no_modifier = not key_event:ctrl() and not key_event:alt() and not key_event:super()
    local plain_digit_key = (not ascii_mode and no_modifier and not shift and not key_event:release()
        and not ctx:is_composing() and (ctx.input or "") == "")
        and key_event_util.digit_char(clean_key, keycode, repr) or nil
    env._standalone_period_after_digit = (no_modifier and not shift and not key_event:release()
        and key_name == "period" and not ctx:is_composing() and env._last_plain_digit_key) or nil
    if plain_digit_key then
        env._last_plain_digit_key = true
    elseif not key_event:release() then
        env._last_plain_digit_key = nil
    end
    local caps_on = key_event_util.effective_caps_on(env, key_event)
    if key_event:release() and no_modifier and env._space_commit_release_guard
        and key_event_util.is_space(keycode, clean_key, repr) then
        env._space_commit_release_guard = nil
        return kAccepted
    end
    local bare_upper = (not ascii_mode and not shift and not caps_on and no_modifier and not key_event:release())
        and key_event_util.bare_upper_alpha_char(clean_key, keycode, repr) or nil
    if bare_upper and ((ctx.input or "") == "" or env._shift_inline_ascii) then
        env._shift_inline_ascii = true
        commit_guard.clear_space(env)
        ctx:push_input(bare_upper)
        return kAccepted
    end
    if not ascii_mode and shift and no_modifier and key_event_util.is_alpha(env, key_name, clean_key, keycode) then
        env._shift_inline_ascii = true
        commit_guard.clear_space(env)
        return kNoop
    end
    if ascii_mode or not ctx:is_composing() or (ctx.input or "") == "" then
        env._shift_inline_ascii = nil
    elseif not key_event:release() and no_modifier and not caps_on
        and key_event_util.shift_inline_alpha(env, ctx, shift, key_name, clean_key, keycode) then
        commit_guard.clear_space(env)
        return kNoop
    end
    if not ascii_mode and no_modifier and ctx:is_composing() and M.get_append_suffix(env, ctx) then
        if key_event:release() then return kAccepted end
        local char = M.append_char(key_name, shift, caps_on, keycode, clean_key, repr)
            or (caps_on and M.symbol_char(key_name, false, true) or nil)
        if char and M.append_suffix(env, ctx, char) then return kAccepted end
    end
    local append_alpha
    if not ascii_mode and no_modifier and ctx:is_composing() then
        if caps_on then
            append_alpha = key_event_util.alpha_upper_char(clean_key, keycode)
        else
            append_alpha = key_event_util.uppercase_char(clean_key, keycode)
        end
    end
    local append_suffix = append_alpha
    if not append_suffix and not ascii_mode and no_modifier and ctx:is_composing() and caps_on then
        append_suffix = M.symbol_char(key_name, false, true)
    end
    if append_suffix then
        commit_guard.clear_space(env)
        if key_event:release() then return kAccepted end
        if M.set_append(env, ctx, append_suffix) then return kAccepted end
    end
    local uppercase = (not ascii_mode and not shift and no_modifier and caps_on)
        and key_event_util.uppercase_char(clean_key, keycode) or nil
    if uppercase then
        commit_guard.clear_space(env)
        if key_event:release() then return kAccepted end
        if ctx:is_composing() then ctx:commit() end
        env.engine:commit_text(uppercase)
        return kAccepted
    end
    local caps_symbol = (not ascii_mode and no_modifier and caps_on)
        and M.symbol_char(key_name, shift, caps_on) or nil
    if caps_symbol then
        commit_guard.clear_space(env)
        if key_event:release() then return kAccepted end
        if ctx:is_composing() then ctx:commit() end
        env.engine:commit_text(caps_symbol)
        return kAccepted
    end
    if ascii_mode then
        commit_guard.clear_space(env)
        return kNoop
    end
    return nil, { ascii_mode = ascii_mode, no_modifier = no_modifier, caps_on = caps_on }
end

return M
