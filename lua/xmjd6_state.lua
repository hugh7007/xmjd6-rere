-- 共享状态工具
-- 管理追加候选属性键、候选隐藏和候选刷新状态。
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-06-04

local config = require("xmjd6_config")
local platform = require("xmjd6_platform")
local candidate = require("xmjd6_candidate")

local M = {}

local string_sub = string.sub

function M.init_append(env, schema_id)
    env._append_input_key, env._append_suffix_key = config.append_keys(schema_id)
end

function M.append_input_key(env)
    return env._append_input_key or "_rime_append_input"
end

function M.append_suffix_key(env)
    return env._append_suffix_key or "_rime_append_suffix"
end

function M.clear_append(env, ctx)
    if not ctx then return end
    local changed = false
    if ctx:get_property(M.append_input_key(env)) ~= "" then
        ctx:set_property(M.append_input_key(env), "")
        changed = true
    end
    if ctx:get_property(M.append_suffix_key(env)) ~= "" then
        ctx:set_property(M.append_suffix_key(env), "")
        changed = true
    end
    if ctx:get_option("_hide_candidate") then
        ctx:set_option("_hide_candidate", false)
        changed = true
    end
    return changed
end

function M.set_append(env, ctx, suffix)
    if not (ctx and ctx:is_composing() and suffix and suffix ~= "" and ctx.input and ctx.input ~= "") then
        M.clear_append(env, ctx)
        return false
    end
    local comp = ctx.composition and ctx.composition:back()
    local has_candidate = ctx:has_menu() or (comp and comp.menu and comp.menu:get_candidate_at(0) ~= nil)
    if not has_candidate then
        M.clear_append(env, ctx)
        return false
    end
    local input_key = M.append_input_key(env)
    local suffix_key = M.append_suffix_key(env)
    local changed = false
    if ctx:get_property(input_key) ~= ctx.input then
        ctx:set_property(input_key, ctx.input)
        changed = true
    end
    if ctx:get_property(suffix_key) ~= suffix then
        ctx:set_property(suffix_key, suffix)
        changed = true
    end
    if not ctx:get_option("_hide_candidate") then
        ctx:set_option("_hide_candidate", true)
        changed = true
    end
    if changed then
        platform.refresh(ctx, env.engine and env.engine.schema and env.engine.schema.config)
    end
    return true
end

function M.get_append_suffix(env, ctx)
    if not ctx then return nil end
    if ctx:get_property(M.append_input_key(env)) ~= ctx.input then return nil end
    local suffix = ctx:get_property(M.append_suffix_key(env))
    if not suffix or suffix == "" then return nil end
    return suffix
end

function M.append_state_changed(env, ctx, source_input, suffix)
    return not ctx:is_composing()
        or ctx.input ~= source_input
        or ctx:get_property(M.append_input_key(env)) ~= source_input
        or ctx:get_property(M.append_suffix_key(env)) ~= suffix
end

function M.append_suffix(env, ctx, suffix)
    local current = M.get_append_suffix(env, ctx)
    if not current or not suffix or suffix == "" then return false end
    local next_suffix = current .. suffix
    if current == next_suffix and ctx:get_option("_hide_candidate") then
        return true
    end
    ctx:set_property(M.append_suffix_key(env), next_suffix)
    if not ctx:get_option("_hide_candidate") then
        ctx:set_option("_hide_candidate", true)
    end
    platform.refresh(ctx, env.engine and env.engine.schema and env.engine.schema.config)
    return true
end

function M.pop_append_suffix(env, ctx)
    local current = M.get_append_suffix(env, ctx)
    if not current then return false end
    local changed = false
    if #current <= 1 then
        changed = M.clear_append(env, ctx) or changed
    else
        local next_suffix = string_sub(current, 1, -2)
        if next_suffix ~= current then
            ctx:set_property(M.append_suffix_key(env), next_suffix)
            changed = true
        end
        if not ctx:get_option("_hide_candidate") then
            ctx:set_option("_hide_candidate", true)
            changed = true
        end
    end
    if changed then
        platform.refresh(ctx, env.engine and env.engine.schema and env.engine.schema.config)
    end
    return true
end

function M.commit_append(env, ctx, engine)
    local suffix = M.get_append_suffix(env, ctx)
    if not suffix then return false end
    local source_input = ctx:get_property(M.append_input_key(env))
    if M.append_state_changed(env, ctx, source_input, suffix) then return false end
    local cand = ctx:get_selected_candidate()
    if not cand then
        local comp = ctx.composition and ctx.composition:back()
        local menu = comp and comp.menu
        cand = menu and menu:get_candidate_at(0)
    end
    if not cand then return false end
    local base = candidate.genuine_text(cand)
    if M.append_state_changed(env, ctx, source_input, suffix) then return false end
    if suffix ~= "" and string_sub(base, -#suffix) == suffix then
        base = string_sub(base, 1, -(#suffix + 1))
    end
    ctx:clear()
    M.clear_append(env, ctx)
    engine:commit_text(base .. suffix)
    return true
end

function M.wrap_append_if_needed(cand, env, ctx, input_text, first)
    if not first then return cand end
    if not ctx then return cand end
    local source_input = ctx:get_property(M.append_input_key(env))
    local suffix = ctx:get_property(M.append_suffix_key(env))
    if source_input ~= input_text or not suffix or suffix == "" then return cand end
    return candidate.wrap_append(cand, suffix)
end

return M
