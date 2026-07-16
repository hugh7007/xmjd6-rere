-- 天行键顶功与自动回退
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-10

local string_byte = string.byte
local string_sub = string.sub
local type = type
local zzc_processor = require("zzc.xmjd6_zzc_processor")
local key_event_util = require("xmjd6_key_event")
local commit_guard = require("xmjd6_commit_guard")

local M = {}
local kAccepted = 1
local kNoop = 2
local CHAR_CACHE = key_event_util.char_cache

function M.ready(env, ctx)
    if env._tc then
        env._tc = env._tc + 1
        if env._tc > 200 then env._tc = 81 end
    elseif env._tc_pending then
        env._tc_pending = false
        local reverse_key = ctx:get_property("_rvk")
        if not reverse_key or reverse_key == "" then env._tc = 0 end
    end
    if env._tc and env._tc >= 80 then
        if ctx:is_composing() then ctx:clear() end
        return false
    end
    return true
end

function M.exec(env)
    local ctx = env.engine.context
    if not M.ready(env, ctx) then return false end
    if zzc_processor and zzc_processor.is_active and zzc_processor.is_active(ctx) then
        local next_input = env._xmjd6_zzc_follow_key
        env._xmjd6_zzc_follow_key = nil
        if zzc_processor.capture_current_candidate and zzc_processor.capture_current_candidate(ctx, next_input) then
            return true, next_input ~= nil
        end
    end
    if commit_guard.commit_selected_non_completion(ctx) then return true, false, true end
    if env._tu_ac then
        ctx:clear()
        return true, false, true
    end
    return true, false, false
end

function M.plain_code_key(env, key, clean_key, keycode)
    if not env._alpha then return nil end
    local code_key
    if keycode >= 65 and keycode <= 90 then
        code_key = CHAR_CACHE[keycode + 32]
    elseif keycode >= 97 and keycode <= 122 then
        code_key = CHAR_CACHE[keycode]
    end
    if not code_key and type(key) == "string" and #key == 1 then
        local byte = string_byte(key, 1)
        if byte >= 65 and byte <= 90 then code_key = CHAR_CACHE[byte + 32]
        elseif byte >= 97 and byte <= 122 then code_key = key end
    end
    if not code_key and type(clean_key) == "string" and #clean_key == 1 then
        local byte = string_byte(clean_key, 1)
        if byte >= 65 and byte <= 90 then code_key = CHAR_CACHE[byte + 32]
        elseif byte >= 97 and byte <= 122 then code_key = clean_key end
    end
    return code_key and env._alpha[code_key] and code_key or nil
end

function M.eval_input(current_input, opts)
    local raw_input = current_input or ""
    local semicolon_input = opts and opts.direct_symbols and type(raw_input) == "string"
        and #raw_input > 0 and string_byte(raw_input, 1) == 59
    local logical_input = raw_input
    if raw_input:sub(1, 1) == "\\" or semicolon_input then logical_input = string_sub(raw_input, 2) end
    local input_len = #logical_input
    return {
        raw_input = raw_input,
        raw_len = #raw_input,
        input = logical_input,
        input_len = input_len,
        first = input_len > 0 and string_sub(logical_input, 1, 1) or "",
        prev = input_len > 0 and string_sub(logical_input, -1) or "",
        semicolon_input = semicolon_input,
    }
end

function M.fixed_rule_would_commit(env, current_input, key, opts)
    local eval = M.eval_input(current_input, opts)
    if eval.input_len < 1 or eval.semicolon_input then return false end
    local is_topup = env._tu_set[key]
    local previous_is_topup = env._tu_set[eval.prev]
    local first_is_topup = env._tu_set[eval.first]
    if env._tu_cmd and first_is_topup then return false end
    if eval.input_len >= (env._tu_max or 6) then return true end
    if previous_is_topup and not is_topup then return true end
    return eval.input_len >= (env._tu_min or 4) and not previous_is_topup and not is_topup
end

function M.auto_fallback(env, ctx, key, opts)
    if env._tu_streaming or not opts.auto_fallback or not env._alpha[key] then return false end
    local zzc_stage = ctx and ctx.get_property and (ctx:get_property("_xmjd6_zzc_stage") or "") or ""
    local zzc_mode = ctx and ctx.get_property and (ctx:get_property("_xmjd6_zzc_mode") or "") or ""
    if zzc_processor and zzc_processor.is_active and zzc_processor.is_active(ctx)
        and zzc_stage == "collect" and zzc_mode == "make" and type(ctx.input) == "string"
        and ctx.input:sub(1, 1) == "\\" then return false end
    local current_input = ctx.input
    local eval = M.eval_input(current_input, opts)
    if eval.raw_len < 1 or M.fixed_rule_would_commit(env, current_input, key, opts) then return false end
    if not commit_guard.has_non_completion_candidate(ctx) then return false end
    if not M.ready(env, ctx) then return kAccepted end
    commit_guard.clear_space(env)
    ctx:push_input(key)
    if commit_guard.has_non_completion_candidate(ctx) then
        commit_guard.note_space(env, ctx, current_input, key)
        return kAccepted
    end
    local pushed_input = ctx.input or ""
    if #pushed_input <= #current_input or string_sub(pushed_input, 1, #current_input) ~= current_input then
        return kAccepted
    end
    ctx:pop_input(1)
    if (ctx.input or "") ~= current_input then return kAccepted end
    if not commit_guard.space_selected_current(ctx, #current_input)
        and not commit_guard.has_non_completion_candidate(ctx) then return kAccepted end
    if zzc_processor and zzc_processor.is_active and zzc_processor.is_active(ctx) then
        if zzc_processor.capture_current_candidate and zzc_processor.capture_current_candidate(ctx, key) then
            return kAccepted
        end
        return false
    end
    if not commit_guard.commit_selected_non_completion(ctx) then return false end
    commit_guard.note_space(env, ctx, "", key)
    return kNoop
end

return M
