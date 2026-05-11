-- 天行键过滤器
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-03

local string_match = string.match
local string_find = string.find
local string_sub = string.sub
local string_byte = string.byte
local utf8_len = utf8.len
local type = type

local DEFAULT_HINT_CACHE_LIMIT = 256
local MAX_HINT_CACHE_LIMIT = 512
local MIN_HINT_CACHE_LIMIT = 64
local DEFAULT_DICT_KEYWORDS = { "xmjd6" }
local CORE_DICT_SUFFIX = "core"

local shared_hint_cache = {}
local shared_hint_cache_count = 0
local active_filter_envs = 0
local shared_reverse_handles = {}

local function clear_shared_hint_cache()
    shared_hint_cache = {}
    shared_hint_cache_count = 0
end

local function clear_shared_reverse_handles()
    for dict_name in pairs(shared_reverse_handles) do
        local handle = shared_reverse_handles[dict_name]
        if handle and handle.close then
            pcall(function() handle:close() end)
        end
        shared_reverse_handles[dict_name] = nil
    end
end

local function close_shared_reverse_handle(dict_name)
    if not dict_name then return end
    local handle = shared_reverse_handles[dict_name]
    if handle and handle.close then
        pcall(function() handle:close() end)
    end
    shared_reverse_handles[dict_name] = nil
end

local function release_hint_state(env, gc_step, close_handle)
    env.reverse_core = nil
    if close_handle then
        close_shared_reverse_handle(env.core_dict_name)
        env.core_dict_name = nil
    end
    if gc_step and gc_step > 0 then
        collectgarbage("step", gc_step)
    end
end

local function startswith(str, start)
    return string_sub(str, 1, #start) == start
end

local function get_first_config_string(config, keys)
    for _, key in ipairs(keys or {}) do
        local value = config:get_string(key)
        if value and value ~= "" then
            return value
        end
    end
    return nil
end

local function trim(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
        return nil
    end
    return s
end

local function push_unique_value(list, seen, value)
    value = trim(value)
    if value and not seen[value] then
        list[#list + 1] = value
        seen[value] = true
    end
end

local function split_keywords(raw)
    if type(raw) ~= "string" then
        return {}
    end
    raw = raw:gsub("[，；|]+", ",")
    local keywords = {}
    local seen = {}
    for value in raw:gmatch("[^,%s]+") do
        push_unique_value(keywords, seen, value)
    end
    return keywords
end

local function build_default_dict_keywords(schema_id)
    local keywords = {}
    local seen = {}
    if schema_id and schema_id ~= "" and schema_id ~= DEFAULT_DICT_KEYWORDS[1] then
        push_unique_value(keywords, seen, schema_id)
    end
    for _, keyword in ipairs(DEFAULT_DICT_KEYWORDS) do
        push_unique_value(keywords, seen, keyword)
    end
    return keywords
end

local function build_dict_names(keywords, suffix)
    local dict_names = {}
    local seen = {}
    suffix = trim(suffix)
    if not suffix then
        return dict_names
    end
    for _, keyword in ipairs(keywords or {}) do
        local dict_name = trim(keyword)
        if dict_name then
            dict_name = dict_name .. "." .. suffix
            if not seen[dict_name] then
                dict_names[#dict_names + 1] = dict_name
                seen[dict_name] = true
            end
        end
    end
    return dict_names
end

local function resolve_core_dict_names(config, schema_id)
    local explicit = trim(get_first_config_string(config, { "core_hint/dictionary" }))
    if explicit then
        return { explicit }
    end

    local keywords = split_keywords(get_first_config_string(config, { "dict_keywords", "reverse_dict_keywords" }))
    if #keywords == 0 then
        keywords = build_default_dict_keywords(schema_id)
    end
    return build_dict_names(keywords, CORE_DICT_SUFFIX)
end

local function open_reverse(env)
    if env.core_dict_name then
        local active = shared_reverse_handles[env.core_dict_name]
        if active then
            env.reverse_core = active
            return
        end
    end

    local config = env.engine.schema.config
    local core_dict_names = resolve_core_dict_names(config, env.schema_id)

    for _, dict_name in ipairs(core_dict_names or {}) do
        local db = shared_reverse_handles[dict_name]
        if not db then
            local ok, opened = pcall(ReverseLookup, dict_name)
            if ok and opened then
                db = opened
                shared_reverse_handles[dict_name] = db
            end
        end
        if db then
            env.core_dict_name = dict_name
            env.reverse_core = db
            return
        end
    end
end

local function segment_has_tag(seg, tag)
    if not seg or not tag or tag == "" then
        return false
    end
    if seg.has_tag then
        local ok, has_tag = pcall(function()
            return seg:has_tag(tag)
        end)
        if ok and has_tag then
            return true
        end
    end
    return seg.tag == tag
end

local function extract_reading(s)
    if type(s) ~= "string" then return nil end
    return string_match(s, "%(([^)]+)%)") or string_match(s, "（([^）]+)）")
end

local function process_hint(cand, env, input_text)
    local text = cand.text
    if not text or #text > 24 then return end

    local reverse = env.reverse_core
    if not reverse then return end

    local cache_key = (env.core_dict_name or "") .. "\0" .. text
    local lookup_result = shared_hint_cache[cache_key]
    if lookup_result == nil then
        lookup_result = reverse:lookup(text)
        if lookup_result and lookup_result ~= "" then
            if shared_hint_cache_count >= env._hint_cache_limit then
                clear_shared_hint_cache()
            end
            shared_hint_cache[cache_key] = lookup_result
            shared_hint_cache_count = shared_hint_cache_count + 1
        end
    end
    if not lookup_result then return end

    local lookup = " " .. lookup_result .. " "
    local short = string_match(lookup, env.p1) or
                  string_match(lookup, env.p2) or
                  string_match(lookup, env.p3) or
                  string_match(lookup, env.p4) or
                  string_match(lookup, env.p5)

    if short then
        local short_len = utf8_len(short)
        if env._input_len_cache > short_len and not startswith(short, input_text) then
            cand:get_genuine().comment = (cand.comment or "") .. " = " .. short
        end
    end
end

local function commit_hint(cand, hint_text)
    cand:get_genuine().comment = hint_text .. (cand.comment or "")
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
        else
            if #input_text > 1 then
                local b1 = string_byte(input_text, 1)
                if b1 == 118 or b1 == 111 then
                    want_reverse = true
                elseif env.is_xmjd and b1 == 117 then
                    want_reverse = true
                end
            end
        end

        if not want_reverse then
             local seg = context.composition and context.composition:back()
             if seg then
                if segment_has_tag(seg, "reverse_lookup")
                    or segment_has_tag(seg, env.gbk_tag)
                    or segment_has_tag(seg, env.erfen_tag)
                    or segment_has_tag(seg, "pinyin_simp") then
                    want_reverse = true
                end
             end
        end
    else
        env._reverse_sticky = false
    end
    if context:get_option("reverse_lookup") ~= want_reverse then
        context:set_option("reverse_lookup", want_reverse)
        if context.is_composing and context:is_composing() then
            context:refresh_non_confirmed_composition()
        end
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
    return segment_has_tag(seg, "reverse_lookup")
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
        if input_len == 0 then
            env._reverse_sticky = false
            release_hint_state(env, 48, true)
        end
    end

    if sbb_on ~= env._last_sbb_on then
        env._last_sbb_on = sbb_on
        if not sbb_on then
            sync_reverse_core(env, false)
        end
    end

    if input_len == 0 then
        release_hint_state(env, 16, true)
    elseif not sbb_on then
        sync_reverse_core(env, false)
    elseif input_len < 4 or input_len > 6 then
        env.reverse_core = nil
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
    local reverse_opened = false

    for cand in input:iter() do
        if should_skip_reverse_lookup_grave(cand, current_seg) then
            goto continue
        end

        if first then
            if show_commit_hint then commit_hint(cand, hint_text) end
            first = false
        end

        if sbb_on and should_query_core_hint(cand) and hint_count < hint_limit then
            hint_count = hint_count + 1
            if input_len >= 4 and input_len <= 6 then
                local has_reading = extract_reading(cand.comment)
                if not has_reading then
                    if not reverse_opened then
                        open_reverse(env)
                        reverse_opened = true
                    end
                    process_hint(cand, env, input_text)
                end
            end
        end

        yield(cand)
        ::continue::
    end
    if reverse_opened then
        env.reverse_core = nil
    end
    env._input_len_cache = nil
end

local function init(env)
    if env._update_conn then env._update_conn:disconnect() end
    if env._commit_conn then env._commit_conn:disconnect() end

    local config = env.engine.schema.config
    env.schema_id = env.engine.schema.schema_id
    env.is_xmjd = string_find(env.schema_id, "xmjd") ~= nil
    env.gbk_tag = get_first_config_string(config, { "gbk/tag" }) or "gbk"
    env.erfen_tag = env.is_xmjd and "quanpinerfen" or "jderfen"
    active_filter_envs = active_filter_envs + 1

    env.reverse_core = nil
    env.core_dict_name = nil

    env.b = config:get_string("topup/topup_with") or ""
    env.s = config:get_string("topup/topup_this") or ""
    env.hint_text = config:get_string('hint_text') or '🚫'

    if env.s ~= "" and env.b ~= "" then
        env.p1 = " ([" .. env.s .. "][" .. env.b .. "]+) "
        env.p2 = " ([" .. env.b .. "][" .. env.b .. "]) "
        env.p3 = " ([" .. env.s .. "][" .. env.s .. "][" .. env.b .. "]) "
        env.p4 = " ([" .. env.b .. "][" .. env.b .. "][" .. env.b .. "]) "
        env.p5 = " ([" .. env.s .. "][" .. env.s .. "]) "
        env.match_s_pattern = "^["..env.s.."]+$"
        env.match_b_pattern = "^["..env.b.."]+$"
    else
        env.p1, env.p2, env.p3, env.p4, env.p5 = "^$", "^$", "^$", "^$", "^$"
        env.match_s_pattern = "^$"
        env.match_b_pattern = "^$"
    end

    local hint_cache_limit = config:get_int("hint_cache_limit") or DEFAULT_HINT_CACHE_LIMIT
    if hint_cache_limit < MIN_HINT_CACHE_LIMIT then
        hint_cache_limit = MIN_HINT_CACHE_LIMIT
    elseif hint_cache_limit > MAX_HINT_CACHE_LIMIT then
        hint_cache_limit = MAX_HINT_CACHE_LIMIT
    end
    env._hint_cache_limit = hint_cache_limit

    local ctx = env.engine.context
    env._last_input_text = ctx.input or ""
    env._last_sbb_on = ctx:get_option("sbb_hint")
    env._update_conn = ctx.update_notifier:connect(function(context)
        if not context:is_composing() then
            env._last_input_text = ""
            env._reverse_sticky = false
            release_hint_state(env, 24, true)
        end
    end)
    env._commit_conn = ctx.commit_notifier:connect(function()
        env._last_input_text = ""
        env._reverse_sticky = false
        release_hint_state(env, 32, true)
    end)

    ctx:set_property("_rvk", tostring(os.time()))
end

local function fini(env)
    if env._update_conn then
        env._update_conn:disconnect()
        env._update_conn = nil
    end
    if env._commit_conn then
        env._commit_conn:disconnect()
        env._commit_conn = nil
    end
    release_hint_state(env, 32, true)
    env._hint_cache_limit = nil
    env._last_input_text = nil
    env._last_sbb_on = nil
    if active_filter_envs > 0 then
        active_filter_envs = active_filter_envs - 1
    end
    if active_filter_envs == 0 then
        clear_shared_hint_cache()
        clear_shared_reverse_handles()
        collectgarbage("step", 64)
    end
end

return { init = init, func = filter, fini = fini }
