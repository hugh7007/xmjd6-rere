-- 天行键候选提交与空格守卫
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-10

local string_find = string.find
local string_match = string.match
local string_sub = string.sub
local type = type
local key_event_util = require("xmjd6_key_event")
local platform = require("common.xmjd6_platform")
local processor_state = require("xmjd6_processor_state")

local M = {}
local kAccepted = 1
local RAW_INPUT_PATTERN = "^[a-z;" .. string.char(39) .. "]+$"

function M.guard_shift_symbol_release(env, shift)
    if shift then env._shift_symbol_release_guard = true end
end

function M.selected_candidate(ctx)
    return ctx and ctx:get_selected_candidate() or nil
end

function M.candidate_type(cand)
    if not cand then return nil end
    local cand_type = cand.type
    if cand.get_genuine then
        local ok, genuine = pcall(function() return cand:get_genuine() end)
        if ok and genuine and genuine.type then cand_type = genuine.type end
    end
    return cand_type
end

function M.is_completion_candidate(cand)
    return M.candidate_type(cand) == "completion"
end

function M.is_raw_input_candidate(ctx, cand)
    local input = ctx and (ctx.input or "") or ""
    if input == "" or not cand or cand.text ~= input then return false end
    local cand_type = M.candidate_type(cand)
    return cand_type == "raw" or cand_type == "ascii" or string_match(input, RAW_INPUT_PATTERN) ~= nil
end

function M.selected_is_non_completion(ctx)
    local cand = M.selected_candidate(ctx)
    return cand and not M.is_completion_candidate(cand) and not M.is_raw_input_candidate(ctx, cand) or false
end

function M.commit_selected_non_completion(ctx)
    local cand = M.selected_candidate(ctx)
    if not cand or M.is_completion_candidate(cand) or M.is_raw_input_candidate(ctx, cand) then return false end
    ctx:commit()
    return true
end

function M.commit_selected_candidate(ctx)
    if not M.selected_candidate(ctx) then return false end
    ctx:commit()
    return true
end

function M.has_non_completion_candidate(ctx)
    local selected = ctx:get_selected_candidate()
    if selected then return not M.is_completion_candidate(selected) and not M.is_raw_input_candidate(ctx, selected) end
    local comp = ctx.composition and ctx.composition:back()
    local menu = comp and comp.menu
    if not menu then return false end
    local ok, cand = pcall(function() return menu:get_candidate_at(0) end)
    return ok and cand and not M.is_completion_candidate(cand) and not M.is_raw_input_candidate(ctx, cand) or false
end

function M.clear_space(env)
    processor_state.clear_space_guard(env)
end

function M.note_space(env, ctx, before_input, key)
    if not env._space_guard_enabled or type(key) ~= "string" or #key ~= 1 then return end
    if not (env._alpha and env._alpha[key]) then return end
    before_input = before_input or (ctx and (ctx.input or "")) or ""
    local expected = before_input .. key
    if #expected >= (env._tu_max or 6) then
        M.clear_space(env)
        return
    end
    env._space_guard_input = expected
    env._space_guard_wait = nil
end

function M.push_code_input(env, ctx, key)
    local before_input = ctx and (ctx.input or "") or ""
    ctx:push_input(key)
    M.note_space(env, ctx, before_input, key)
end

function M.space_selected_current(ctx, input_len)
    local cand = M.selected_candidate(ctx)
    if not cand then return false end
    local cand_end = cand._end
    if type(cand_end) == "number" and cand_end > 0 and cand_end < input_len then return false end
    local comp = ctx.composition and ctx.composition:back()
    local seg_end = comp and comp._end
    if type(seg_end) == "number" and seg_end > 0 and seg_end < input_len then return false end
    return true
end

function M.space_hold_current(env, ctx, current)
    if not current or current == "" or #current < (env._tu_max or 6) then return false end
    if M.space_selected_current(ctx, #current) then return false end
    if env._space_guard_refreshed_input == current then return true end
    if platform.refresh(ctx, env.engine.schema.config) then
        env._space_guard_refreshed_input = current
        return true
    end
    return false
end

function M.process_space(env, ctx, key_event, clean_key, repr, keycode, no_modifier)
    if not (env._space_guard_enabled and no_modifier and key_event_util.is_space(keycode, clean_key, repr)) then
        return nil
    end
    local input_text = ctx and (ctx.input or "") or ""
    if input_text ~= "" then
        if string_find(input_text, "`", 1, true) then return nil end
        if env._rx_prefix and env._rx_prefix[string_sub(input_text, 1, 1)] then return nil end
    end
    if key_event:release() then
        local expected = env._space_guard_wait
        if not expected then return nil end
        env._space_guard_wait = nil
        local current = ctx.input or ""
        local selected_current = ctx:is_composing() and M.space_selected_current(ctx, #current)
        if current == expected and selected_current then M.commit_selected_candidate(ctx) end
        M.clear_space(env)
        return kAccepted
    end
    local expected = env._space_guard_input
    if not expected or expected == "" or not ctx:is_composing() then
        M.clear_space(env)
        return nil
    end
    local current = ctx.input or ""
    if current ~= expected then
        env._space_guard_wait = expected
        return kAccepted
    end
    if M.space_hold_current(env, ctx, current) then
        env._space_guard_wait = expected
        return kAccepted
    end
    M.clear_space(env)
    return nil
end

function M.commit_menu_index(ctx, engine, index)
    local comp = ctx.composition:back()
    if not comp or not comp.menu then return false end
    local cand = comp.menu:get_candidate_at(index)
    if not cand then return false end
    ctx:clear()
    engine:commit_text(cand.text)
    return true
end

return M

