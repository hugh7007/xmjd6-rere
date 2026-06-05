-- 文本映射过滤器
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-06-03

local M = {}
local config_util = require("xmjd6_config")
local opencc_data = require("xmjd6_opencc_data")
local list_size = config_util.list_size

local DEFAULT_DELIMITER = "|"
local DEFAULT_COMMENT_FORMAT = "〔%s〕"
local FMM_CACHE_LIMIT = 2048
local LOOKUP_CACHE_LIMIT = 4096
local DENSE_CODE_LEN = 6

local insert = table.insert
local concat = table.concat
local s_match = string.match
local s_gmatch = string.gmatch
local s_format = string.format
local s_byte = string.byte
local s_sub = string.sub
local s_gsub = string.gsub
local s_find = string.find
local s_lower = string.lower
local type = type
local next = next
local ipairs = ipairs
local pairs = pairs
local pcall = pcall

local fmm_cache = {}
local fmm_cache_size = 0
local lookup_cache = {}
local lookup_cache_size = 0
local shared_pending = {}
local shared_comments = {}
local shared_results = {}
local shared_parts = {}

local function clear_table(t)
    for i = 1, #t do
        t[i] = nil
    end
end

local function put_fmm_cache(key, value)
    if fmm_cache_size >= FMM_CACHE_LIMIT then
        fmm_cache = {}
        fmm_cache_size = 0
    end
    fmm_cache[key] = value
    fmm_cache_size = fmm_cache_size + 1
end

local function put_lookup_cache(key, value)
    if lookup_cache_size >= LOOKUP_CACHE_LIMIT then
        lookup_cache = {}
        lookup_cache_size = 0
    end
    lookup_cache[key] = value
    lookup_cache_size = lookup_cache_size + 1
end

local function reset_runtime_tables(clear_fmm)
    if clear_fmm then
        fmm_cache = {}
        fmm_cache_size = 0
        lookup_cache = {}
        lookup_cache_size = 0
    end
    clear_table(shared_pending)
    clear_table(shared_comments)
    clear_table(shared_results)
    clear_table(shared_parts)
end

local function module_namespace(env)
    local ns = env.name_space or ""
    ns = s_gsub(ns, "^%*", "")
    ns = s_match(ns, "([^%.]+)$") or ns
    if ns ~= "" then
        return ns
    end

    local source = debug and debug.getinfo and debug.getinfo(1, "S")
    local source_path = source and source.source or ""
    local name = s_match(source_path, "([^/\\]+)%.lua$")
    return name or "opencc_filter"
end

local function clear_runtime_state(clear_fmm)
    local had_runtime_state = (clear_fmm and fmm_cache_size > 0)
        or next(shared_pending) ~= nil
        or next(shared_comments) ~= nil
        or next(shared_results) ~= nil
        or next(shared_parts) ~= nil
    reset_runtime_tables(clear_fmm)
    return had_runtime_state
end

local function get_utf8_offsets(text)
    local offsets = {}
    local len = #text
    local i = 1
    while i <= len do
        insert(offsets, i)
        local b = s_byte(text, i)
        if b < 128 then
            i = i + 1
        elseif b < 224 then
            i = i + 2
        elseif b < 240 then
            i = i + 3
        else
            i = i + 4
        end
    end
    insert(offsets, len + 1)
    return offsets
end

local function segment_has_tag(seg, tag)
    return config_util.segment_has_tag(seg, tag)
end

local function is_reverse_lookup_context(ctx, env)
    if not ctx then
        return false
    end
    local input_text = ctx.input or ""
    if s_find(input_text, "`", 1, true) then
        return true
    end
    local prefixes = env and env._reverse_prefixes
    if prefixes and prefixes[s_sub(input_text, 1, 1)] then
        return true
    end
    local seg = ctx.composition and ctx.composition:back()
    if not seg then
        return false
    end
    local tags = env and env._reverse_tags
    if tags then
        for _, tag in ipairs(tags) do
            if segment_has_tag(seg, tag) then
                return true
            end
        end
        return false
    end
    return segment_has_tag(seg, "reverse_lookup")
end

local function rule_is_active(rule, ctx, seg)
    local is_active = false
    for _, trigger in ipairs(rule.triggers) do
        if trigger == true then
            is_active = true
            break
        elseif type(trigger) == "string" and ctx:get_option(trigger) then
            is_active = true
            break
        end
    end
    if not is_active then
        return false
    end

    if rule.tags then
        for req_tag, _ in pairs(rule.tags) do
            if segment_has_tag(seg, req_tag) then
                return true
            end
        end
        return false
    end
    return true
end

local function collect_enabled_datasets(rules, ctx)
    local active_datasets = {}
    if not rules or not ctx then
        return active_datasets
    end
    for _, rule in ipairs(rules) do
        local provider = rule.provider
        if provider and provider.dataset_name then
            for _, trigger in ipairs(rule.triggers) do
                if trigger == true or (type(trigger) == "string" and ctx:get_option(trigger)) then
                    active_datasets[provider.dataset_name] = true
                    break
                end
            end
        end
    end
    return active_datasets
end

local function provider_fetch(rule, text)
    if not rule or not rule.provider or not text or text == "" then
        return nil
    end
    local cache_key = rule.lookup_cache_prefix and (rule.lookup_cache_prefix .. text) or nil
    if cache_key then
        local cached = lookup_cache[cache_key]
        if cached ~= nil then
            return cached or nil
        end
    end
    local ok, val = pcall(function()
        return rule.provider:fetch(text)
    end)
    if not ok then
        if cache_key then
            put_lookup_cache(cache_key, false)
        end
        return nil
    end
    if not val and s_find(text, "%u") then
        ok, val = pcall(function()
            return rule.provider:fetch(s_lower(text))
        end)
        if not ok then
            if cache_key then
                put_lookup_cache(cache_key, false)
            end
            return nil
        end
    end
    if cache_key then
        put_lookup_cache(cache_key, val or false)
    end
    return val
end

local function segment_convert(text, rule, split_pat)
    local offsets = get_utf8_offsets(text)
    local char_count = #offsets - 1
    local result_parts = {}
    local i = 1
    local max_lookahead = 6

    while i <= char_count do
        local start_byte = offsets[i]
        local matched = false
        local max_j = i + max_lookahead
        if max_j > char_count + 1 then
            max_j = char_count + 1
        end

        for j = max_j, i + 2, -1 do
            local end_byte = offsets[j] - 1
            local sub_text = s_sub(text, start_byte, end_byte)
            local cache_key = (rule.prefix or "") .. sub_text
            local val = fmm_cache[cache_key]
            if val == nil then
                put_fmm_cache(cache_key, provider_fetch(rule, sub_text) or false)
                val = fmm_cache[cache_key]
            end
            if val then
                local first_val = s_match(val, split_pat)
                insert(result_parts, first_val or sub_text)
                i = j - 1
                matched = true
                break
            end
        end

        if not matched then
            local single_char = s_sub(text, start_byte, offsets[i + 1] - 1)
            local cache_key = (rule.prefix or "") .. single_char
            local val = fmm_cache[cache_key]
            if val == nil then
                put_fmm_cache(cache_key, provider_fetch(rule, single_char) or false)
                val = fmm_cache[cache_key]
            end
            if val then
                local first_val = s_match(val, split_pat)
                insert(result_parts, first_val or single_char)
            else
                insert(result_parts, single_char)
            end
        end

        i = i + 1
    end

    return concat(result_parts)
end

local function append_emoji_chunk(chunk, out)
    if not chunk or chunk == "" then
        return
    end
    insert(out, chunk)
end

local function append_split_items(out, raw_value, split_pat, split_mode, source_text)
    if not raw_value or raw_value == "" then
        return
    end

    local escaped_source = nil
    if split_mode == "emoji" and source_text and source_text ~= "" then
        escaped_source = s_gsub(source_text, "[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%1")
    end

    for part in s_gmatch(raw_value, split_pat) do
        if split_mode == "emoji" then
            part = s_match(part, "^%s*(.-)%s*$") or part
            if escaped_source then
                part = s_gsub(part, "^" .. escaped_source .. "%s*", "")
            end
            for chunk in s_gmatch(part, "%S+") do
                append_emoji_chunk(chunk, out)
            end
        else
            insert(out, part)
        end
    end
end

local function process_rules(cand, active_rules, split_pat, comment_fmt, is_chain, emoji_tail, allow_emoji, dense_emoji_mode)
    clear_table(shared_results)
    if cand.type == "completion" then
        local has_non_emoji_rule = false
        for _, rule in ipairs(active_rules) do
            if rule.split_mode ~= "emoji" then
                has_non_emoji_rule = true
                break
            end
        end
        if not has_non_emoji_rule then
            insert(shared_results, cand)
            return shared_results
        end
    end

    local current_text = cand.text
    local show_main = true
    local current_main_comment = cand.comment
    local matched_cand_type = nil

    clear_table(shared_pending)
    clear_table(shared_comments)

    for _, rule in ipairs(active_rules) do
        if rule.split_mode == "emoji" and (cand.type == "completion" or not allow_emoji) then
            goto continue_rule
        end

        local query_text = is_chain and current_text or cand.text
        local val = provider_fetch(rule, query_text)
        local allow_fmm = rule.fmm and not (dense_emoji_mode and rule.split_mode == "emoji")
        if not val and allow_fmm then
            local seg_key = (rule.prefix or "") .. "\0" .. query_text
            local seg_result = fmm_cache[seg_key]
            if seg_result == nil then
                seg_result = segment_convert(query_text, rule, split_pat)
                put_fmm_cache(seg_key, seg_result)
            end
            if seg_result ~= query_text then
                val = seg_result
            end
        end

        if val then
            matched_cand_type = rule.cand_type or matched_cand_type

            local mode = rule.mode
            local rule_comment = ""
            if rule.comment_mode == "text" then
                rule_comment = cand.text
            elseif rule.comment_mode == "comment" then
                rule_comment = cand.comment
            end
            if mode ~= "comment" and rule_comment ~= "" then
                rule_comment = s_format(comment_fmt, rule_comment)
            end

            if mode == "comment" then
                clear_table(shared_parts)
                for p in s_gmatch(val, split_pat) do
                    insert(shared_parts, p)
                end
                if #shared_parts > 0 then
                    insert(shared_comments, concat(shared_parts, " "))
                end
            elseif mode == "replace" then
                if is_chain then
                    local first = true
                    for p in s_gmatch(val, split_pat) do
                        if first then
                            current_text = p
                            if rule.comment_mode == "none" then
                                current_main_comment = ""
                            elseif rule.comment_mode == "text" then
                                current_main_comment = cand.text
                            end
                            first = false
                        else
                            insert(shared_pending, { text = p, comment = rule_comment })
                        end
                    end
                else
                    show_main = false
                    for p in s_gmatch(val, split_pat) do
                        insert(shared_pending, { text = p, comment = rule_comment })
                    end
                end
            elseif mode == "append" then
                clear_table(shared_parts)
                append_split_items(shared_parts, val, split_pat, rule.split_mode, cand.text)
                for _, p in ipairs(shared_parts) do
                    if rule.split_mode == "emoji" then
                        insert(emoji_tail, {
                            cand_type = rule.cand_type or cand.type or "derived",
                            start_pos = cand.start,
                            end_pos = cand._end,
                            text = p,
                            comment = rule_comment,
                            preedit = cand.preedit,
                            quality = cand.quality,
                        })
                    else
                        insert(shared_pending, { text = p, comment = rule_comment })
                    end
                end
            end
        end

        ::continue_rule::
    end

    if #shared_comments > 0 then
        current_main_comment = s_format(comment_fmt, concat(shared_comments, " "))
    end

    if show_main then
        if is_chain and current_text ~= cand.text then
            local final_type = matched_cand_type or cand.type or "kv"
            local nc = Candidate(final_type, cand.start, cand._end, current_text, current_main_comment)
            nc.preedit = cand.preedit
            nc.quality = cand.quality
            insert(shared_results, nc)
        else
            cand.comment = current_main_comment
            insert(shared_results, cand)
        end
    end

    for _, item in ipairs(shared_pending) do
        if not (show_main and item.text == current_text) then
            local final_type = matched_cand_type or cand.type or "derived"
            local nc = Candidate(final_type, cand.start, cand._end, item.text, item.comment)
            nc.preedit = cand.preedit
            nc.quality = cand.quality
            insert(shared_results, nc)
        end
    end

    return shared_results
end

function M.init(env)
    local ns = module_namespace(env)

    local schema_id = env.engine.schema.schema_id or nil

    local source = debug and debug.getinfo and debug.getinfo(1, "S")
    local source_path = source and source.source or ""
    local base_dir = nil
    if s_match(source_path, "^@") then
        base_dir = s_match(s_sub(source_path, 2) or "", "^(.*[/\\])") or ""
    end
    opencc_data.set_context(base_dir, schema_id)

    local config = env.engine.schema.config
    env._reverse_tags, env._reverse_prefixes = config_util.collect_reverse_context(config, schema_id, false)

    env.delimiter = config:get_string(ns .. "/delimiter") or DEFAULT_DELIMITER
    env.comment_format = config:get_string(ns .. "/comment_format") or DEFAULT_COMMENT_FORMAT
    env.chain = config:get_bool(ns .. "/chain")
    if env.chain == nil then
        env.chain = false
    end
    env.rules = {}

    if env.delimiter == " " then
        env.split_pattern = "%S+"
    else
        local esc = s_gsub(env.delimiter, "[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%1")
        env.split_pattern = "([^" .. esc .. "]+)"
    end

    local rules_path = ns .. "/rules"
    local rule_list = config:get_list(rules_path)
    if not rule_list then
        return
    end

    for i = 0, list_size(rule_list) - 1 do
        local entry_path = rules_path .. "/@" .. i
        local triggers = {}
        local opts_keys = { "option", "options" }

        for _, key in ipairs(opts_keys) do
            local key_path = entry_path .. "/" .. key
            local list = config:get_list(key_path)
            if list then
                for k = 0, list_size(list) - 1 do
                    local val = config:get_string(key_path .. "/@" .. k)
                    if val then
                        insert(triggers, val)
                    end
                end
            else
                if config:get_bool(key_path) == true then
                    insert(triggers, true)
                else
                    local val = config:get_string(key_path)
                    if val and val ~= "true" then
                        insert(triggers, val)
                    end
                end
            end
        end

        if #triggers == 0 then
            goto continue_rule_init
        end

        local target_tags = nil
        local tag_keys = { "tag", "tags" }
        for _, key in ipairs(tag_keys) do
            local key_path = entry_path .. "/" .. key
            local list = config:get_list(key_path)
            if list then
                if not target_tags then
                    target_tags = {}
                end
                for k = 0, list_size(list) - 1 do
                    local val = config:get_string(key_path .. "/@" .. k)
                    if val then
                        target_tags[val] = true
                    end
                end
            else
                local val = config:get_string(key_path)
                if val then
                    if not target_tags then
                        target_tags = {}
                    end
                    target_tags[val] = true
                end
            end
        end

        local prefix = config:get_string(entry_path .. "/prefix") or ""
        local mode = config:get_string(entry_path .. "/mode") or "append"
        local comment_mode = config:get_string(entry_path .. "/comment_mode")
        if not comment_mode then
            comment_mode = "comment"
        end
        local fmm = config:get_bool(entry_path .. "/sentence")
        if fmm == nil then
            fmm = false
        end
        local custom_cand_type = config:get_string(entry_path .. "/cand_type")
        local split_mode = config:get_string(entry_path .. "/split")
        local value_mode = split_mode == "emoji" and "raw" or "first"

        local provider = nil
        local static_dataset_name = config:get_string(entry_path .. "/dataset_name")
        if static_dataset_name == "" then
            static_dataset_name = nil
        end

        if static_dataset_name then
            provider = opencc_data.create_provider(static_dataset_name, value_mode)
        end

        if provider then
            insert(env.rules, {
                triggers = triggers,
                tags = target_tags,
                prefix = prefix,
                mode = mode,
                comment_mode = comment_mode,
                fmm = fmm,
                cand_type = custom_cand_type,
                split_mode = split_mode,
                provider = provider,
                lookup_cache_prefix = static_dataset_name .. "\0" .. value_mode .. "\0" .. prefix .. "\0",
            })
        end

        ::continue_rule_init::
    end
end

function M.fini(env)
    env.rules = nil
    env._reverse_tags = nil
    env._reverse_prefixes = nil
    clear_runtime_state(true)
    opencc_data.release_all()
    collectgarbage("step", 240)
end

function M.func(input, env)
    local ctx = env.engine.context
    local rules = env.rules
    local split_pat = env.split_pattern
    local comment_fmt = env.comment_format
    local is_chain = env.chain
    local enabled_datasets = collect_enabled_datasets(rules, ctx)
    local input_len = #(ctx.input or "")

    if not ctx:is_composing() or ctx.input == "" then
        local had_runtime_state = clear_runtime_state()
        if opencc_data.release_inactive(enabled_datasets) then
            had_runtime_state = true
            clear_runtime_state(true)
        end
        if had_runtime_state then
            collectgarbage("step", 120)
        end
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    if not rules or #rules == 0 then
        if opencc_data.release_inactive(enabled_datasets) then
            clear_runtime_state(true)
            collectgarbage("step", 120)
        end
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local seg = ctx.composition:back()
    local in_reverse_lookup = is_reverse_lookup_context(ctx, env)
    local active_rules = {}
    local emoji_tail = {}
    local emoji_flushed_before_completion = false
    local fixed_count = 0
    local emoji_limit = env.engine.schema.page_size or 5
    if emoji_limit <= 0 then emoji_limit = 5 end
    local dense_emoji_mode = ctx:get_option("emoji_cn") and input_len >= DENSE_CODE_LEN
    for _, rule in ipairs(rules) do
        local skip_for_reverse = in_reverse_lookup and rule.split_mode == "emoji"
        if not skip_for_reverse and rule.provider and rule_is_active(rule, ctx, seg) then
            insert(active_rules, rule)
        end
    end

    if #active_rules == 0 then
        if opencc_data.release_inactive(enabled_datasets) then
            clear_runtime_state(true)
            collectgarbage("step", 120)
        end
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local function flush_emoji_tail()
        for _, item in ipairs(emoji_tail) do
            local nc = Candidate(item.cand_type, item.start_pos, item.end_pos, item.text, item.comment)
            nc.preedit = item.preedit
            nc.quality = item.quality
            yield(nc)
        end
        clear_table(emoji_tail)
    end

    for cand in input:iter() do
        local is_completion = cand.type == "completion"
        if is_completion and not emoji_flushed_before_completion then
            flush_emoji_tail()
            emoji_flushed_before_completion = true
        end
        local allow_emoji = false
        if not is_completion then
            fixed_count = fixed_count + 1
            allow_emoji = fixed_count <= emoji_limit
        end
        local processed = process_rules(
            cand,
            active_rules,
            split_pat,
            comment_fmt,
            is_chain,
            emoji_tail,
            allow_emoji,
            dense_emoji_mode
        )
        for _, item in ipairs(processed) do
            yield(item)
        end
    end

    flush_emoji_tail()

    if opencc_data.release_inactive(enabled_datasets) then
        clear_runtime_state(true)
        collectgarbage("step", 120)
    end
end

return M
