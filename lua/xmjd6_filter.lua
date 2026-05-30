-- 天行键过滤器
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-29

local config_util = require("xmjd6_config")
local platform = require("xmjd6_platform")
local candidate_util = require("xmjd6_candidate")
local reverse = require("xmjd6_reverse")
local state = require("xmjd6_state")

local string_match = string.match
local string_find = string.find
local string_sub = string.sub
local utf8_len = utf8.len

local active_filter_envs = 0

local function release_hint_state(env, gc_step, close_handle)
    local had_state = env.core_dict_name ~= nil
    if close_handle then
        reverse.close(env.core_dict_name)
        env.core_dict_name = nil
    end
    if had_state and gc_step and gc_step > 0 then
        collectgarbage("step", gc_step)
    end
end

local function release_hint_state_for_context(env, ctx, gc_step)
    local close_handle = not (ctx and ctx.get_option and ctx:get_option("sbb_hint"))
    release_hint_state(env, gc_step, close_handle)
end

local function startswith(str, start)
    return string_sub(str, 1, #start) == start
end

local function open_reverse(env)
    if env.core_dict_name then return true end
    env.core_dict_name = reverse.open_first(env.core_dict_names)
    return env.core_dict_name ~= nil
end

local function extract_short_hint(raw_text, env, input_text)
    if type(raw_text) ~= "string" or raw_text == "" then return nil end
    local lookup = " " .. raw_text .. " "
    local short = string_match(lookup, env.p1) or
                  string_match(lookup, env.p2) or
                  string_match(lookup, env.p3) or
                  string_match(lookup, env.p4) or
                  string_match(lookup, env.p5)

    if short then
        local short_len = utf8_len(short)
        if env._input_len_cache > short_len and not startswith(short, input_text) then
            return short
        end
    end
    return nil
end

local function has_short_hint(comment)
    return type(comment) == "string" and string_find(comment, " = ", 1, true) ~= nil
end

local function process_hint(cand, env, input_text)
    local text = cand.text
    if not text or #text > 24 or has_short_hint(cand.comment) then return end

    local cache = env._hint_input_cache
    local cache_key = text
    local cached = cache and cache[cache_key]
    if cached ~= nil then
        if cached then
            candidate_util.append_comment(cand, " = " .. cached)
        end
        return
    end

    local short = nil
    local core_result, core_checked = reverse.lookup_core_hint(env.core_dict_names, text)
    if core_checked then
        short = extract_short_hint(core_result, env, input_text)
        if cache then cache[cache_key] = short or false end
        if short then
            candidate_util.append_comment(cand, " = " .. short)
        end
        return
    end

    if not short then
        if not open_reverse(env) then
            if cache then cache[cache_key] = false end
            return
        end
        short = extract_short_hint(reverse.lookup_hint(env.core_dict_name, text, env._hint_cache_limit), env, input_text)
    end

    if cache then cache[cache_key] = short or false end
    if short then
        candidate_util.append_comment(cand, " = " .. short)
    end
end

local function commit_hint(cand, hint_text)
    candidate_util.set_comment(cand, hint_text .. (cand.comment or ""))
end

local function should_query_core_hint(cand)
    return cand.type == "table"
end

local function update_lazy_reverse(env, context, input_text)
    if not context then return end
    input_text = input_text or ""
    local want_reverse = false

    if input_text ~= "" then
        if string_find(input_text, "`", 1, true) then
            env._reverse_sticky = true
        end

        if env._reverse_sticky then
            want_reverse = true
        elseif config_util.input_has_reverse_prefix(input_text, env._reverse_prefixes, 2) then
            want_reverse = true
        end

        if not want_reverse then
            want_reverse = config_util.context_has_reverse_tag(context, env._reverse_tags)
        end
    else
        env._reverse_sticky = false
        env._reverse_refresh_key = nil
    end

    if context:get_option("reverse_lookup") ~= want_reverse then
        context:set_option("reverse_lookup", want_reverse)
        local refresh_key = input_text .. "\0" .. tostring(want_reverse)
        if env._reverse_refresh_key ~= refresh_key then
            env._reverse_refresh_key = refresh_key
            if context.is_composing and context:is_composing() then
                platform.refresh(context, env.engine.schema.config)
            end
        end
    else
        env._reverse_refresh_key = input_text .. "\0" .. tostring(want_reverse)
    end
end

local function sync_reverse_core(env, on)
    if not on then
        release_hint_state(env, nil, true)
    end
end

local function should_skip_reverse_lookup_grave(cand, seg)
    if not cand or cand.text ~= "`" then
        return false
    end
    return config_util.segment_has_tag(seg, "reverse_lookup")
end

local function filter(input, env)
    local context = env.engine.context
    local input_text = context.input
    local input_len = #input_text
    local sbb_on = context:get_option("sbb_hint")
    local current_seg = context.composition and context.composition:back()

    update_lazy_reverse(env, context, input_text)

    if input_text ~= env._last_input_text then
        env._last_input_text = input_text
        env._hint_input_cache = {}
        if context:get_property(state.append_input_key(env)) ~= input_text then
            state.clear_append(env, context)
        end
        if input_len == 0 then
            env._reverse_sticky = false
            release_hint_state_for_context(env, context, 48)
        end
    end

    if sbb_on ~= env._last_sbb_on then
        env._last_sbb_on = sbb_on
        if not sbb_on then
            sync_reverse_core(env, false)
        end
    end

    if input_len == 0 then
        release_hint_state_for_context(env, context, 16)
    elseif not sbb_on then
        sync_reverse_core(env, false)
    end

    local hint_text = env.hint_text

    env._input_len_cache = utf8_len(input_text)

    local show_commit_hint = false
    if env.s ~= "" and env.b ~= "" then
        if #input_text < 4 and string_match(input_text, env.match_s_pattern) then
            show_commit_hint = true
        elseif string_match(input_text, env.match_b_pattern) then
            show_commit_hint = true
        end
    end

    local first = true
    local hint_count = 0
    local hint_limit = env.engine.schema.page_size or 5
    if hint_limit <= 0 then hint_limit = 5 end

    for cand in input:iter() do
        if should_skip_reverse_lookup_grave(cand, current_seg) then
            goto continue
        end

        local was_first = first
        if first then
            if show_commit_hint then commit_hint(cand, hint_text) end
            first = false
        end

        if sbb_on and should_query_core_hint(cand) and hint_count < hint_limit then
            hint_count = hint_count + 1
            if input_len >= 4 and input_len <= 6 then
                if not candidate_util.has_reading(cand.comment) then
                    process_hint(cand, env, input_text)
                end
            end
        end

        yield(state.wrap_append_if_needed(cand, env, context, input_text, was_first))
        ::continue::
    end
    env._input_len_cache = nil
end

local function init(env)
    platform.safe_disconnect(env._update_conn)
    platform.safe_disconnect(env._commit_conn)

    local config = env.engine.schema.config
    env.schema_id = env.engine.schema.schema_id or ""
    env._reverse_tags, env._reverse_prefixes = config_util.collect_reverse_context(config, env.schema_id, false)
    state.init_append(env, env.schema_id)
    if not env._filter_active then
        active_filter_envs = active_filter_envs + 1
        env._filter_active = true
    end
    if not env._reverse_shared_acquired then
        reverse.acquire()
        env._reverse_shared_acquired = true
    end

    env.core_dict_name = nil
    env.core_dict_names = config_util.resolve_core_dict_names(config, env.schema_id)
    env._reverse_refresh_key = nil

    env.b = config:get_string("topup/topup_with") or ""
    env.s = config:get_string("topup/topup_this") or ""
    env.hint_text = config:get_string("hint_text") or "🚫"

    if env.s ~= "" and env.b ~= "" then
        env.p1 = " ([" .. env.s .. "][" .. env.b .. "]+) "
        env.p2 = " ([" .. env.b .. "][" .. env.b .. "]) "
        env.p3 = " ([" .. env.s .. "][" .. env.s .. "][" .. env.b .. "]) "
        env.p4 = " ([" .. env.b .. "][" .. env.b .. "][" .. env.b .. "]) "
        env.p5 = " ([" .. env.s .. "][" .. env.s .. "]) "
        env.match_s_pattern = "^[" .. env.s .. "]+$"
        env.match_b_pattern = "^[" .. env.b .. "]+$"
    else
        env.p1, env.p2, env.p3, env.p4, env.p5 = "^$", "^$", "^$", "^$", "^$"
        env.match_s_pattern = "^$"
        env.match_b_pattern = "^$"
    end

    env._hint_cache_limit = reverse.cache_limit(config, "hint_cache_limit")
    env._hint_input_cache = {}

    local ctx = env.engine.context
    env._last_input_text = ctx.input or ""
    env._last_sbb_on = ctx:get_option("sbb_hint")

    local notifier_override = config:get_string("xmjd6/platform/enable_notifier")
    if notifier_override ~= "false" and notifier_override ~= "0" and notifier_override ~= "no" then
        env._update_conn = platform.safe_connect(ctx.update_notifier, function(context)
            if not context:is_composing() then
                env._last_input_text = ""
                env._reverse_sticky = false
                env._reverse_refresh_key = nil
                release_hint_state_for_context(env, context, 24)
            end
        end)
        env._commit_conn = platform.safe_connect(ctx.commit_notifier, function()
            env._last_input_text = ""
            env._reverse_sticky = false
            env._reverse_refresh_key = nil
            state.clear_append(env, ctx)
            release_hint_state_for_context(env, ctx, 32)
        end)
    end

    ctx:set_property("_rvk", tostring(os.time()))
end

local function fini(env)
    platform.safe_disconnect(env._update_conn)
    platform.safe_disconnect(env._commit_conn)
    env._update_conn = nil
    env._commit_conn = nil

    release_hint_state(env, 32, true)
    env._hint_cache_limit = nil
    env._hint_input_cache = nil
    env._last_input_text = nil
    env._last_sbb_on = nil
    env._reverse_refresh_key = nil
    env._reverse_tags = nil
    env._reverse_prefixes = nil
    env._append_input_key = nil
    env._append_suffix_key = nil
    env.core_dict_names = nil

    if env._filter_active and active_filter_envs > 0 then
        active_filter_envs = active_filter_envs - 1
    end
    env._filter_active = nil
    if env._reverse_shared_acquired then
        reverse.release()
        env._reverse_shared_acquired = nil
    end
end

return { init = init, func = filter, fini = fini }
