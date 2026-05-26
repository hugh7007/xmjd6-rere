-- 文本映射过滤器
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-10

local M = {}

local DEFAULT_NAMESPACE = "txjx_opencc_filter"
local DEFAULT_DELIMITER = "|"
local DEFAULT_COMMENT_FORMAT = "〔%s〕"
local FMM_CACHE_LIMIT = 2048
local PHRASE_SHARD_CACHE_LIMIT = 8

local insert = table.insert
local remove = table.remove
local concat = table.concat
local s_match = string.match
local s_gmatch = string.gmatch
local s_format = string.format
local s_byte = string.byte
local s_sub = string.sub
local s_gsub = string.gsub
local s_find = string.find
local s_lower = string.lower
local open = io.open
local type = type
local next = next
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local dofile = dofile

local fmm_cache = {}
local fmm_cache_size = 0
local shared_pending = {}
local shared_comments = {}
local shared_results = {}
local shared_parts = {}
local normalize_mapping_value

local shared_static = {
    datasets = {},
    phrase_shards = {},
    phrase_usage = {},
    base_dir = nil,
    schema_id = nil,
}

local function clear_table(t)
    for i = 1, #t do
        t[i] = nil
    end
end

local function clear_map(t)
    for k, _ in pairs(t) do
        t[k] = nil
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

local function reset_runtime_tables()
    fmm_cache = {}
    fmm_cache_size = 0
    shared_pending = {}
    shared_comments = {}
    shared_results = {}
    shared_parts = {}
end

local function clear_runtime_state()
    local had_runtime_state = fmm_cache_size > 0
        or next(shared_pending) ~= nil
        or next(shared_comments) ~= nil
        or next(shared_results) ~= nil
        or next(shared_parts) ~= nil
    reset_runtime_tables()
    return had_runtime_state
end

local function dirname(path)
    return s_match(path or "", "^(.*[/\\])") or ""
end

local function list_size(list)
    if not list then
        return 0
    end
    local ok, value = pcall(function()
        return list.size
    end)
    if ok and type(value) == "number" then
        return value
    end
    ok, value = pcall(function()
        return list:size()
    end)
    if ok and type(value) == "number" then
        return value
    end
    return 0
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

local function utf8_first_char(text)
    local b = s_byte(text or "", 1)
    if not b then
        return nil
    end
    local len = 1
    if b >= 240 then
        len = 4
    elseif b >= 224 then
        len = 3
    elseif b >= 192 then
        len = 2
    end
    return s_sub(text, 1, len)
end

local function join_path(base, relative)
    if not base or base == "" then
        return relative
    end
    return base .. "/" .. relative
end

local function push_unique_candidate(candidates, seen, path)
    if path and path ~= "" and not seen[path] then
        seen[path] = true
        insert(candidates, path)
    end
end

local function trim_trailing_sep(path)
    return s_gsub(path or "", "[/\\]+$", "")
end

local function collect_project_dirs()
    local dirs = {}
    local seen = {}

    local function push(path)
        path = trim_trailing_sep(path)
        if path ~= "" and not seen[path] then
            seen[path] = true
            insert(dirs, path)
        end
    end

    local lua_dir = shared_static.base_dir or ""
    local project_dir = lua_dir ~= "" and dirname(s_sub(lua_dir, 1, -2)) or ""
    if project_dir ~= "" then
        push(project_dir)
    elseif lua_dir ~= "" then
        push(".")
    end

    local api = rime_api
    if api and api.get_user_data_dir then
        local ok, user_dir = pcall(api.get_user_data_dir)
        if ok and type(user_dir) == "string" and user_dir ~= "" then
            push(user_dir)
        end
    end

    local schema_id = shared_static.schema_id or ""
    local pkg_path = package and package.path or nil
    if type(pkg_path) == "string" and pkg_path ~= "" and schema_id ~= "" then
        local marker = "/" .. schema_id .. "/"
        for entry in s_gmatch(pkg_path, "[^;]+") do
            local prefix = s_match(entry, "^(.*)%?")
            if prefix and prefix ~= "" then
                prefix = trim_trailing_sep(s_gsub(prefix, "\\", "/"))
                local prefixed = prefix .. "/"
                local at = s_find(prefixed, marker, 1, true)
                if at then
                    push(s_sub(prefixed, 1, at + #marker - 2))
                elseif s_match(prefix, "/lua$") then
                    local parent = s_sub(prefix, 1, -5)
                    if parent == "" then
                        push(".")
                        push(schema_id)
                    else
                        push(parent)
                        push(join_path(parent, schema_id))
                    end
                end
            end
        end
    end

    if schema_id ~= "" then
        push(schema_id)
        local user_dir = nil
        if api and api.get_user_data_dir then
            local ok, value = pcall(api.get_user_data_dir)
            if ok and type(value) == "string" and value ~= "" then
                user_dir = value
            end
        end
        if user_dir then
            push(join_path(user_dir, schema_id))
        end
    end

    return dirs
end

local function build_project_candidates(relative)
    local candidates = {}
    local seen = {}
    if not relative or relative == "" then
        return candidates
    end

    for _, project_dir in ipairs(collect_project_dirs()) do
        push_unique_candidate(candidates, seen, join_path(project_dir, relative))
    end

    return candidates
end

local function find_existing_path(candidates)
    local tried = {}
    for _, path in ipairs(candidates) do
        if path and path ~= "" and not tried[path] then
            tried[path] = true
            local f = open(path, "r")
            if f then
                f:close()
                return path
            end
        end
    end
    return nil
end

local function load_lua_table(relative_path)
    if relative_path == "" then
        return nil
    end
    local path = find_existing_path(build_project_candidates("opencc/Data/" .. relative_path))
    if not path then
        return nil
    end
    local ok, mod = pcall(dofile, path)
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function touch_phrase_shard(module_name)
    local usage = shared_static.phrase_usage
    for i = #usage, 1, -1 do
        if usage[i] == module_name then
            remove(usage, i)
            break
        end
    end
    insert(usage, module_name)
    while #usage > PHRASE_SHARD_CACHE_LIMIT do
        local expired = remove(usage, 1)
        if expired and expired ~= module_name then
            shared_static.phrase_shards[expired] = nil
            pcall(function()
                if package and package.loaded then
                    package.loaded[expired] = nil
                end
            end)
        end
    end
end

local function clear_dataset_phrase_shards(dataset)
    if not dataset or not dataset.name then
        return
    end
    local prefix = dataset.name .. "_phrases_"
    for module_name, _ in pairs(shared_static.phrase_shards) do
        if s_match(module_name, "^" .. prefix) then
            shared_static.phrase_shards[module_name] = nil
        end
    end
    local usage = shared_static.phrase_usage
    local i = 1
    while i <= #usage do
        if s_match(usage[i], "^" .. prefix) then
            remove(usage, i)
        else
            i = i + 1
        end
    end
end

local function ensure_dataset_loaded(dataset_name)
    if not dataset_name or dataset_name == "" then
        return nil
    end
    local dataset = shared_static.datasets[dataset_name]
    if dataset then
        if not dataset.chars then
            dataset.chars = load_lua_table(dataset.name .. "_chars.lua") or {}
        end
        if not dataset.index then
            dataset.index = load_lua_table(dataset.name .. "_phrases_index.lua") or {}
        end
        return dataset
    end

    dataset = {
        name = dataset_name,
        chars = load_lua_table(dataset_name .. "_chars.lua") or {},
        index = load_lua_table(dataset_name .. "_phrases_index.lua") or {},
    }
    shared_static.datasets[dataset_name] = dataset
    return dataset
end

local function get_dataset_phrase_shard(dataset, text)
    if not dataset then
        return nil
    end
    local first = utf8_first_char(text)
    if not first then
        return nil
    end
    local bucket = dataset.index[first]
    if not bucket then
        return nil
    end
    local module_name = dataset.name .. "_phrases_" .. bucket .. ".lua"
    local shard = shared_static.phrase_shards[module_name]
    if not shard then
        shard = load_lua_table(module_name)
        if not shard then
            return nil
        end
        shared_static.phrase_shards[module_name] = shard
    end
    touch_phrase_shard(module_name)
    return shard
end

local function create_static_opencc_provider(dataset_name, value_mode)
    return {
        dataset_name = dataset_name,
        value_mode = value_mode,
        fetch = function(self, text)
            if not text or text == "" then
                return nil
            end
            local dataset = ensure_dataset_loaded(self.dataset_name)
            if not dataset then
                return nil
            end
            local shard = get_dataset_phrase_shard(dataset, text)
            if shard then
                local phrase_val = normalize_mapping_value(shard[text], self.value_mode)
                if phrase_val and phrase_val ~= "" then
                    return phrase_val
                end
            end
            return normalize_mapping_value(dataset.chars[text], self.value_mode)
        end,
        release = function(self)
            local dataset = shared_static.datasets[self.dataset_name]
            if not dataset then
                return
            end
            clear_dataset_phrase_shards(dataset)
        end,
    }
end

function normalize_mapping_value(value, value_mode)
    if not value or value == "" then
        return nil
    end
    value = s_match(value, "^%s*(.-)%s*$") or value
    if value == "" then
        return nil
    end
    if value_mode == "first" then
        return s_match(value, "^%S+") or value
    end
    return value
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

local function is_reverse_lookup_context(ctx)
    if not ctx then
        return false
    end
    local input_text = ctx.input or ""
    if s_find(input_text, "`", 1, true) or s_match(input_text, "^[vo]") then
        return true
    end
    local seg = ctx.composition and ctx.composition:back()
    if not seg then
        return false
    end
    return segment_has_tag(seg, "reverse_lookup")
        or segment_has_tag(seg, "jderfen")
        or segment_has_tag(seg, "gbk")
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

local function provider_fetch(rule, text)
    if not rule or not rule.provider or not text or text == "" then
        return nil
    end
    local ok, val = pcall(function()
        return rule.provider:fetch(text)
    end)
    if not ok then
        return nil
    end
    if not val and s_find(text, "%u") then
        ok, val = pcall(function()
            return rule.provider:fetch(s_lower(text))
        end)
        if not ok then
            return nil
        end
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

local function process_rules(cand, active_rules, split_pat, comment_fmt, is_chain, emoji_tail)
    clear_table(shared_results)
    local current_text = cand.text
    local show_main = true
    local current_main_comment = cand.comment
    local matched_cand_type = nil

    clear_table(shared_pending)
    clear_table(shared_comments)

    for _, rule in ipairs(active_rules) do
        if cand.type == "completion" and rule.split_mode == "emoji" then
            goto continue_rule
        end

        local query_text = is_chain and current_text or cand.text
        local val = provider_fetch(rule, query_text)
        if not val and rule.fmm then
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
    local ns = env.name_space or ""
    ns = s_gsub(ns, "^%*", "")
    ns = s_match(ns, "([^%.]+)$") or ns
    if ns == "" then
        ns = DEFAULT_NAMESPACE
    end

    shared_static.schema_id = env.engine.schema.schema_id or nil

    local source = debug and debug.getinfo and debug.getinfo(1, "S")
    local source_path = source and source.source or ""
    if s_match(source_path, "^@") then
        shared_static.base_dir = dirname(s_sub(source_path, 2))
    end

    local config = env.engine.schema.config

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
            provider = create_static_opencc_provider(static_dataset_name, value_mode)
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
            })
        end

        ::continue_rule_init::
    end
end

function M.fini(env)
    env.rules = nil
    clear_runtime_state()
    clear_map(shared_static.phrase_shards)
    clear_table(shared_static.phrase_usage)
    collectgarbage("collect")
    collectgarbage("step", 200)
end

function M.func(input, env)
    local ctx = env.engine.context
    local rules = env.rules
    local split_pat = env.split_pattern
    local comment_fmt = env.comment_format
    local is_chain = env.chain

    if not ctx:is_composing() or ctx.input == "" then
        local had_runtime_state = clear_runtime_state()
        if had_runtime_state then
            collectgarbage("step", 120)
        end
        if rules then
            for _, rule in ipairs(rules) do
                if rule.provider and rule.provider.release and not rule_is_active(rule, ctx, nil) then
                    rule.provider:release()
                end
            end
        end
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    if not rules or #rules == 0 then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local seg = ctx.composition:back()
    local in_reverse_lookup = is_reverse_lookup_context(ctx)
    local active_rules = {}
    local emoji_tail = {}
    local completion_tail = {}
    for _, rule in ipairs(rules) do
        local skip_for_reverse = in_reverse_lookup and rule.split_mode == "emoji"
        if not skip_for_reverse and rule.provider and rule_is_active(rule, ctx, seg) then
            insert(active_rules, rule)
        elseif rule.provider and rule.provider.release then
            rule.provider:release()
        end
    end

    if #active_rules == 0 then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    for cand in input:iter() do
        local processed = process_rules(cand, active_rules, split_pat, comment_fmt, is_chain, emoji_tail)
        if cand.type == "completion" then
            for _, item in ipairs(processed) do
                insert(completion_tail, item)
            end
        else
            for _, item in ipairs(processed) do
                yield(item)
            end
        end
    end

    for _, item in ipairs(emoji_tail) do
        local nc = Candidate(item.cand_type, item.start_pos, item.end_pos, item.text, item.comment)
        nc.preedit = item.preedit
        nc.quality = item.quality
        yield(nc)
    end

    for _, item in ipairs(completion_tail) do
        yield(item)
    end
end

return M
