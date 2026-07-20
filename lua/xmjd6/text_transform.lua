-- Text formatting helpers for xmjd6.
-- Pure functions stay independent from Rime so they can be unit-tested.

local M = {}

local WRAPPERS = {
    double_quote = { "“", "”" },
    corner = { "「", "」" },
    white_corner = { "『", "』" },
    book = { "《", "》" },
    full_paren = { "（", "）" },
    full_bracket = { "【", "】" },
    bracket = { "[", "]" },
    paren = { "(", ")" },
    code = { "`", "`" },
    markdown_bold = { "**", "**" },
}

function M.wrap(text, wrapper_id)
    local pair = WRAPPERS[wrapper_id]
    if not pair then
        return nil
    end
    return pair[1] .. tostring(text or "") .. pair[2]
end

function M.to_lower(text)
    return string.lower(tostring(text or ""))
end

function M.to_upper(text)
    return string.upper(tostring(text or ""))
end

local function words(text)
    text = tostring(text or "")
    if text == "" then
        return {}
    end

    -- Preserve a non-Latin string as one unit instead of deleting it while
    -- normalizing separators for developer-oriented identifiers.
    if not text:find("[%w_%- ]") then
        return { text }
    end

    text = text:gsub("[_%-]+", " ")
    local out = {}
    for word in text:gmatch("[^%s]+") do
        local cleaned = word:gsub("[^%w\128-\255]+", "")
        if cleaned ~= "" then
            out[#out + 1] = string.lower(cleaned)
        end
    end
    return out
end

local function capitalize(word)
    if word == "" then
        return ""
    end
    return string.upper(word:sub(1, 1)) .. word:sub(2)
end

function M.to_snake(text)
    return table.concat(words(text), "_")
end

function M.to_kebab(text)
    return table.concat(words(text), "-")
end

function M.to_camel(text)
    local parts = words(text)
    if #parts == 0 then
        return ""
    end
    local out = { parts[1] }
    for i = 2, #parts do
        out[#out + 1] = capitalize(parts[i])
    end
    return table.concat(out)
end

function M.to_pascal(text)
    local parts = words(text)
    for i = 1, #parts do
        parts[i] = capitalize(parts[i])
    end
    return table.concat(parts)
end

function M.to_constant(text)
    return string.upper(M.to_snake(text))
end

function M.join(items, separator)
    items = items or {}
    local last_index = 0
    for key in pairs(items) do
        if type(key) == "number" and key > last_index and key == math.floor(key) then
            last_index = key
        end
    end

    local out = {}
    for i = 1, last_index do
        local text = tostring(items[i] or "")
        if text ~= "" then
            out[#out + 1] = text
        end
    end
    return table.concat(out, tostring(separator or ""))
end

local WRAPPER_ORDER = {
    "double_quote",
    "corner",
    "white_corner",
    "book",
    "full_paren",
    "full_bracket",
    "bracket",
    "paren",
    "code",
    "markdown_bold",
}

local staged_source = nil
local PALETTE_SOURCE_PROPERTY = "xmjd6_text_transform_source"
local PALETTE_INPUT_PROPERTY = "xmjd6_text_transform_original_input"

local function set_context_property(context, name, value)
    if not context or type(context.set_property) ~= "function" then
        return false
    end
    return pcall(function() context:set_property(name, value or "") end)
end

local function get_context_property(context, name)
    if not context or type(context.get_property) ~= "function" then
        return ""
    end
    local ok, value = pcall(function() return context:get_property(name) end)
    return ok and tostring(value or "") or ""
end

local function clear_staged_property(context)
    set_context_property(context, PALETTE_SOURCE_PROPERTY, "")
    set_context_property(context, PALETTE_INPUT_PROPERTY, "")
end

local function config_string(env, key, default)
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    if config and config.get_string then
        local ok, value = pcall(function() return config:get_string(key) end)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return default
end

local function key_repr(key)
    if not key or type(key.repr) ~= "function" then
        return ""
    end
    local ok, value = pcall(function() return key:repr() end)
    return ok and tostring(value or "") or ""
end

local function current_history()
    local state = _G.__dynamic_phrase_state or {}
    if type(state.commit_history) == "table" then
        return state.commit_history
    end
    if type(state.last_commit_text) == "string" and state.last_commit_text ~= "" then
        return { state.last_commit_text }
    end
    return {}
end

local function latest_history_text()
    local items = current_history()
    for i = #items, 1, -1 do
        local text = tostring(items[i] or "")
        if text ~= "" then
            return text
        end
    end
    return nil
end

local function selected_candidate_text(context)
    if context and type(context.get_selected_candidate) == "function" then
        local ok, cand = pcall(function() return context:get_selected_candidate() end)
        if ok and cand and type(cand.text) == "string" and cand.text ~= "" then
            return cand.text
        end
    end
    return nil
end

local function selected_text(context, prefer_commit_text)
    -- Sentence mode may contain multiple confirmed/selected segments.  The
    -- last selected candidate is only the tail, while get_commit_text() is
    -- the complete text that Space would commit.
    if prefer_commit_text and context and type(context.get_commit_text) == "function" then
        local ok, text = pcall(function() return context:get_commit_text() end)
        if ok and type(text) == "string" and text ~= "" then
            return text
        end
    end
    return selected_candidate_text(context)
end

function M.processor(key, env)
    if not key or (type(key.release) == "function" and key:release()) then
        return 2
    end

    local context = env and env.engine and env.engine.context
    if not context then
        return 2
    end

    local input = tostring(context.input or "")
    if staged_source and input ~= "=wrap" then
        staged_source = nil
    end

    local repr = key_repr(key)
    if input == "=wrap" and repr == "BackSpace" then
        local original_input = get_context_property(context, PALETTE_INPUT_PROPERTY)
        if original_input ~= "" then
            local ok = pcall(function() context.input = original_input end)
            if ok and tostring(context.input or "") == original_input then
                clear_staged_property(context)
                staged_source = nil
                return 1
            end
        end
    end
    local hotkey = config_string(env, "text_transform/hotkey", "Control+g")
    local sentence_hotkey = config_string(env, "text_transform/sentence_hotkey", "slash")
    local sentence_prefix = config_string(env, "text_transform/sentence_prefix", "'")
    local in_sentence_mode = sentence_prefix ~= ""
        and input:sub(1, #sentence_prefix) == sentence_prefix
        and #input > #sentence_prefix
    local slash_wrap = repr == sentence_hotkey
    if repr ~= hotkey and not slash_wrap then
        if input ~= "=wrap" then
            clear_staged_property(context)
        end
        return 2
    end

    if type(context.get_option) == "function" then
        local ok, ascii_mode = pcall(function() return context:get_option("ascii_mode") end)
        if ok and ascii_mode then
            return 2
        end
    end

    -- Slash is syntax inside every '=' tool/command (for example calculator
    -- division and =add/=del paths), so it must never be stolen by the text
    -- processing palette while such an input is being composed.
    if slash_wrap and (input == "sjx" or input:sub(1, 1) == "=") then
        return 2
    end

    local text = selected_text(context, in_sentence_mode)
    if not text then
        return 2
    end

    staged_source = text
    set_context_property(context, PALETTE_SOURCE_PROPERTY, text)
    set_context_property(context, PALETTE_INPUT_PROPERTY, input)
    -- Replace input in one update.  clear()+push_input() emits two update
    -- notifications; sentence translation can recompose confirmed segments
    -- between them and produce input such as "=wrap我们了".
    local ok = pcall(function() context.input = "=wrap" end)
    if not ok or tostring(context.input or "") ~= "=wrap" then
        staged_source = nil
        return 2
    end
    return 1
end

local function make_candidate(seg, text, comment, quality, preedit)
    local cand = Candidate("text_transform", seg.start, seg._end, text, comment or "")
    cand.quality = quality or 100000
    if preedit and preedit ~= "" then
        cand.preedit = preedit
    end
    return cand
end

local function yield_unique(seg, values, comment, preedit)
    local seen = {}
    local quality = 100000
    for _, text in ipairs(values) do
        if type(text) == "string" and text ~= "" and not seen[text] then
            seen[text] = true
            yield(make_candidate(seg, text, comment, quality, preedit))
            quality = quality - 1
        end
    end
end

local function transform_values(source)
    local values = {}
    for _, wrapper_id in ipairs(WRAPPER_ORDER) do
        values[#values + 1] = M.wrap(source, wrapper_id)
    end
    if source:find("[A-Za-z]") then
        values[#values + 1] = M.to_lower(source)
        values[#values + 1] = M.to_upper(source)
        values[#values + 1] = M.to_snake(source)
        values[#values + 1] = M.to_kebab(source)
        values[#values + 1] = M.to_camel(source)
        values[#values + 1] = M.to_pascal(source)
        values[#values + 1] = M.to_constant(source)
    end
    return values
end

local JOIN_SEPARATORS = {
    { "、", "顿号连接" },
    { "，", "中文逗号连接" },
    { ", ", "英文逗号连接" },
    { " ", "空格连接" },
    { "\n", "换行连接" },
}

local function recent_items(count)
    local history = current_history()
    local first = math.max(1, #history - count + 1)
    local out = {}
    for i = first, #history do
        local text = tostring(history[i] or "")
        if text ~= "" then
            out[#out + 1] = text
        end
    end
    return out
end

function M.translator(input, seg, env)
    if input == "=wrap" then
        local context = env and env.engine and env.engine.context
        local source = get_context_property(context, PALETTE_SOURCE_PROPERTY)
        if source == "" then source = staged_source end
        local comment = "加工·未上屏"
        if not source or source == "" then
            source = latest_history_text()
            comment = "历史·请先撤销原文"
        end
        if not source or source == "" then
            return
        end
        yield_unique(seg, transform_values(source), comment, comment == "加工·未上屏" and source or nil)
        return
    end

    local count = input:match("^=join/(%d+)$")
    count = tonumber(count)
    if not count or count < 2 or count > 20 then
        return
    end
    local items = recent_items(count)
    if #items < 2 then
        return
    end
    local quality = 100000
    for _, entry in ipairs(JOIN_SEPARATORS) do
        yield(make_candidate(seg, M.join(items, entry[1]), entry[2] .. "·需撤销原文", quality))
        quality = quality - 1
    end
end

function M.func(first, second, third)
    if type(first) == "string" then
        return M.translator(first, second, third)
    end
    return M.processor(first, second)
end

M.WRAPPERS = WRAPPERS

return M
