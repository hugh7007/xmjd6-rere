-- 天行键配置工具
-- 统一读取反查标签、字典名、追加候选属性键等配置。
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-29

local M = {}

local type = type
local string_sub = string.sub

function M.trim(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

function M.get_string(config, path)
    local value = config and config:get_string(path)
    return M.trim(value)
end

function M.get_first_string(config, keys)
    for _, key in ipairs(keys or {}) do
        local value = M.get_string(config, key)
        if value then return value end
    end
    return nil
end

function M.list_size(list)
    if not list then return 0 end
    local ok, value = pcall(function() return list.size end)
    if ok and type(value) == "number" then return value end
    ok, value = pcall(function() return list:size() end)
    if ok and type(value) == "number" then return value end
    return 0
end

function M.push_unique(list, seen, value)
    value = M.trim(value)
    if value and not seen[value] then
        seen[value] = true
        list[#list + 1] = value
    end
end

function M.add_config_tags(config, tags, seen, path)
    local list = config and config:get_list(path)
    if list then
        for i = 0, M.list_size(list) - 1 do
            M.push_unique(tags, seen, config:get_string(path .. "/@" .. i))
        end
        return
    end
    M.push_unique(tags, seen, M.get_string(config, path))
end

function M.schema_stem(schema_id)
    if type(schema_id) ~= "string" or schema_id == "" then return "" end
    return (schema_id:gsub("%d+$", ""))
end

local function add_reverse_section(config, tags, seen_tags, prefixes, section)
    local prefix = M.get_string(config, section .. "/prefix")
    if not prefix then return end
    M.push_unique(tags, seen_tags, M.get_string(config, section .. "/tag") or section)
    if #prefix == 1 then prefixes[prefix] = true end
end

function M.collect_reverse_context(config, schema_id, include_aux)
    local tags, seen_tags = {}, {}
    local prefixes = {}

    M.push_unique(tags, seen_tags, "reverse_lookup")
    M.add_config_tags(config, tags, seen_tags, "reverse_lookup/tags")
    M.add_config_tags(config, tags, seen_tags, "jderfen_lookup/tags")
    M.add_config_tags(config, tags, seen_tags, "gbk_lookup/tags")

    local sections = { "jderfen", "gbk", "quanpinerfen", "pinyin_simp" }
    if schema_id and schema_id ~= "" then
        sections[#sections + 1] = schema_id .. "gbk"
        if include_aux then
            sections[#sections + 1] = schema_id .. "WXYZ"
            local stem = M.schema_stem(schema_id)
            if stem ~= "" then
                sections[#sections + 1] = stem .. "WXYZ"
            end
        end
    end

    for _, section in ipairs(sections) do
        add_reverse_section(config, tags, seen_tags, prefixes, section)
    end

    for _, tag in ipairs(tags) do
        local prefix = M.get_string(config, tag .. "/prefix")
        if prefix and #prefix == 1 then prefixes[prefix] = true end
    end

    return tags, prefixes
end

function M.collect_reverse_prefixes(config, schema_id, include_aux)
    local _, prefixes = M.collect_reverse_context(config, schema_id, include_aux)
    return prefixes
end

function M.segment_has_tag(seg, tag)
    if not seg or not tag or tag == "" then return false end
    if seg.has_tag then
        local ok, has_tag = pcall(function()
            return seg:has_tag(tag)
        end)
        if ok and has_tag then return true end
    end
    return seg.tag == tag
end

function M.context_has_reverse_tag(ctx, tags)
    local seg = ctx and ctx.composition and ctx.composition:back()
    if not seg then return false end
    if tags then
        for _, tag in ipairs(tags) do
            if M.segment_has_tag(seg, tag) then return true end
        end
        return false
    end
    return M.segment_has_tag(seg, "reverse_lookup")
end

function M.input_has_reverse_prefix(input, prefixes, min_len)
    if type(input) ~= "string" or input == "" or not prefixes then return false end
    if min_len and #input < min_len then return false end
    return prefixes[string_sub(input, 1, 1)] == true
end

function M.is_reverse_context(ctx, tags, prefixes, prefix_min_len)
    if not ctx then return false end
    local input = ctx.input or ""
    if input:find("`", 1, true) then return true end
    if M.input_has_reverse_prefix(input, prefixes, prefix_min_len) then return true end
    return M.context_has_reverse_tag(ctx, tags)
end

function M.split_keywords(raw)
    if type(raw) ~= "string" then return {} end
    raw = raw:gsub("[，；|]+", ",")
    local keywords, seen = {}, {}
    for value in raw:gmatch("[^,%s]+") do
        M.push_unique(keywords, seen, value)
    end
    return keywords
end

function M.first_keyword(config, schema_id)
    local raw = M.get_first_string(config, { "dict_keywords", "reverse_dict_keywords" })
    local keywords = M.split_keywords(raw)
    if #keywords > 0 then return keywords[1] end
    if type(schema_id) == "string" and schema_id ~= "" then return schema_id end
    return "rime"
end

function M.resolve_pron_dict(config, schema_id)
    local explicit = M.get_string(config, "reverse_hint/dictionary")
    if explicit then return explicit end
    return M.first_keyword(config, schema_id) .. ".cx"
end

function M.resolve_core_dict_names(config, schema_id)
    local explicit = M.get_string(config, "core_hint/dictionary")
    if explicit then return { explicit } end

    local raw = M.get_first_string(config, { "dict_keywords", "reverse_dict_keywords" })
    local keywords = M.split_keywords(raw)
    if #keywords == 0 and type(schema_id) == "string" and schema_id ~= "" then
        keywords[#keywords + 1] = schema_id
    end

    local dict_names, seen = {}, {}
    for _, keyword in ipairs(keywords) do
        local dict_name = keyword .. ".core"
        if not seen[dict_name] then
            seen[dict_name] = true
            dict_names[#dict_names + 1] = dict_name
        end
    end
    return dict_names
end

function M.clamp_cache_limit(value, default_value, min_value, max_value)
    value = value or default_value
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

function M.s2set(str)
    local t = {}
    if type(str) ~= "string" then return t end
    for i = 1, #str do
        t[string_sub(str, i, i)] = true
    end
    return t
end

function M.append_keys(schema_id)
    local key_schema = (type(schema_id) == "string" and schema_id ~= "") and schema_id or "rime"
    return "_" .. key_schema .. "_append_input", "_" .. key_schema .. "_append_suffix"
end

return M
