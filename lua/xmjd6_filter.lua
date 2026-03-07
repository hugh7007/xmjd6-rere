-- 天行键过滤器 
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-02-26

local string_match = string.match
local string_find = string.find
local string_sub = string.sub
local string_byte = string.byte
local utf8_len = utf8.len
local type = type

local function close_reverse(env)
    if env.reverse_core then
        if env.reverse_core.close then
            pcall(function() env.reverse_core:close() end)
        end
        env.reverse_core = nil
        env._core_using_dict = nil
    end
end

local function open_reverse(env)
    if env.reverse_core then return end
    local db
    if env.core_dict_name then
        db = ReverseLookup(env.core_dict_name)
        if db then
            env.reverse_core = db
            env._core_using_dict = env.core_dict_name
            return
        end
    end
    if env.dict_name then
        db = ReverseLookup(env.dict_name)
        if db then
            env.reverse_core = db
            env._core_using_dict = env.dict_name
        end
    end
end

local function startswith(str, start)
    return string_sub(str, 1, #start) == start
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

    local cache = env._hint_table
    local lookup_result = cache[text]
    if lookup_result == nil then
        lookup_result = reverse:lookup(text)
        cache[text] = lookup_result or false
    end
    if not lookup_result then return end

    local lookup = " " .. lookup_result .. " "
    local short = string_match(lookup, env.p1) or
                  string_match(lookup, env.p2) or
                  string_match(lookup, env.p3) or
                  string_match(lookup, env.p4)

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

local ctx_handlers = setmetatable({}, { __mode = "k" })

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
                local tag = seg.tag
                if tag == "reverse_lookup" or tag == env.gbk_tag or tag == env.erfen_tag or tag == "pinyin_simp" then
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
    if on then
        open_reverse(env)
    else
        close_reverse(env)
    end
end

local function filter(input, env)
    local context = env.engine.context
    local input_text = context.input

    sync_reverse_core(env, context:get_option("sbb_hint"))

    local hint_mode = (env.reverse_core ~= nil)
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
    local hint_done = false

    for cand in input:iter() do
        if first then
            if show_commit_hint then commit_hint(cand, hint_text) end
            first = false
        end

        if hint_mode and not hint_done and cand.type ~= "completion" then
            local ilen = #input_text
            if ilen >= 4 and ilen <= 6 then
                local has_reading = extract_reading(cand.comment)
                if not has_reading then
                    process_hint(cand, env, input_text)
                end
            end
            hint_done = true
        end

        yield(cand)
    end
    env._input_len_cache = nil
end

local function init(env)
    local config = env.engine.schema.config
    env.schema_id = env.engine.schema.schema_id
    env.is_xmjd = string_find(env.schema_id, "xmjd") ~= nil
    env.gbk_tag = env.schema_id .. "gbk"
    env.erfen_tag = env.is_xmjd and "quanpinerfen" or "jderfen"

    close_reverse(env)

    env.dict_name = config:get_string("translator/dictionary")
    env.core_dict_name = (env.dict_name and env.dict_name ~= "") and env.dict_name:gsub("%.extended$", ".core") or nil
    
    env.b = config:get_string("topup/topup_with") or ""
    env.s = config:get_string("topup/topup_this") or ""
    env.hint_text = config:get_string('hint_text') or '🚫'

    if env.s ~= "" and env.b ~= "" then
        env.p1 = " ([" .. env.s .. "][" .. env.b .. "]+) "
        env.p2 = " ([" .. env.b .. "][" .. env.b .. "]) "
        env.p3 = " ([" .. env.s .. "][" .. env.s .. "][" .. env.b .. "]) "
        env.p4 = " ([" .. env.b .. "][" .. env.b .. "][" .. env.b .. "]) "
        env.match_s_pattern = "^["..env.s.."]+$"
        env.match_b_pattern = "^["..env.b.."]+$"
    else
        env.p1, env.p2, env.p3, env.p4 = "^$", "^$", "^$", "^$"
        env.match_s_pattern = "^$"
        env.match_b_pattern = "^$"
    end

    env.commit_counter = 0
    env._hint_table = {}

    local ctx = env.engine.context
    
    if ctx_handlers[ctx] then
        if env._lazy_rev_handler then pcall(function() ctx.update_notifier:disconnect(env._lazy_rev_handler) end) end
        if env._commit_handler then pcall(function() ctx.commit_notifier:disconnect(env._commit_handler) end) end
        if env._option_handler then pcall(function() ctx.option_update_notifier:disconnect(env._option_handler) end) end
    end
    ctx_handlers[ctx] = true

    local function on_update(context) update_lazy_reverse(env, context, context.input) end
    env._lazy_rev_handler = on_update
    ctx.update_notifier:connect(on_update)
    
    local function on_commit(context)
        env.commit_counter = (env.commit_counter or 0) + 1
        update_lazy_reverse(env, context, "")
    end
    env._commit_handler = on_commit
    ctx.commit_notifier:connect(on_commit)
    
    local function on_option(context, opname)
        if opname == "sbb_hint" then sync_reverse_core(env, context:get_option("sbb_hint")) end
    end
    env._option_handler = on_option
    ctx.option_update_notifier:connect(on_option)
    
    sync_reverse_core(env, ctx:get_option("sbb_hint"))

    ctx:set_property("_rvk", tostring(os.time()))
end

local function fini(env)
    local ctx = env.engine and env.engine.context
    if ctx then
        if env._commit_handler then pcall(function() ctx.commit_notifier:disconnect(env._commit_handler) end) end
        if env._lazy_rev_handler then pcall(function() ctx.update_notifier:disconnect(env._lazy_rev_handler) end) end
        if env._option_handler then pcall(function() ctx.option_update_notifier:disconnect(env._option_handler) end) end
        ctx_handlers[ctx] = nil
    end
    close_reverse(env)
    env._hint_table = nil
end

return { init = init, func = filter, fini = fini }