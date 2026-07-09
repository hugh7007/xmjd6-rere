-- 天行键 自造词编码模块
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-02

local M = {}

function M.utf8_chars(text)
    local chars = {}
    local start = 1
    while text and start <= #text do
        local next_start = utf8.offset(text, 2, start)
        if next_start then
            chars[#chars + 1] = text:sub(start, next_start - 1)
            start = next_start
        else
            chars[#chars + 1] = text:sub(start)
            break
        end
    end
    return chars
end

local function same_parts(a, b)
    return a and b and a.s == b.s and a.y == b.y and a.p == b.p
end

function M.hint_matches(entry, hint)
    if not hint then return true end
    if type(hint) == "string" then
        return entry.code and (entry.code:sub(1, #hint) == hint or hint:sub(1, #entry.code) == entry.code)
    end
    if hint.code_prefix and hint.code_prefix ~= "" then
        local prefix = hint.code_prefix
        if not entry.code or (entry.code:sub(1, #prefix) ~= prefix and prefix:sub(1, #entry.code) ~= entry.code) then
            return false
        end
    end
    if hint.s and hint.s ~= "" and entry.s ~= hint.s then return false end
    if hint.y and hint.y ~= "" and entry.y ~= hint.y then return false end
    if hint.p and hint.p ~= "" and entry.p ~= hint.p then return false end
    return true
end

function M.collapse_options(options)
    local first = options and options[1]
    if not first then return nil end
    for i = 2, #options do
        if not same_parts(first, options[i]) then
            return nil
        end
    end
    return first
end

function M.code_at(items, n)
    if n == 2 then
        return items[1].parts.s .. items[1].parts.y .. items[2].parts.s .. items[2].parts.y .. items[1].parts.p .. items[2].parts.p
    elseif n == 3 then
        return items[1].parts.s .. items[2].parts.s .. items[3].parts.s .. items[1].parts.p .. items[2].parts.p .. items[3].parts.p
    end
    return items[1].parts.s .. items[2].parts.s .. items[3].parts.s .. items[#items].parts.s .. items[1].parts.p .. items[2].parts.p
end

function M.code_for_items(items, len)
    local n = #items
    if n < 2 then return nil, "too_short" end
    len = tonumber(len)
    if not len then return nil, "bad_length" end
    if n == 2 and (len < 4 or len > 6) then return nil, "bad_length" end
    if n == 3 and (len < 3 or len > 6) then return nil, "bad_length" end
    if n >= 4 and (len < 4 or len > 6) then return nil, "bad_length" end
    for _, item in ipairs(items or {}) do
        if not item.parts then return nil, "missing_parts" end
    end
    return M.code_at(items, n):sub(1, len)
end

function M.word_from_items(items)
    local parts = {}
    for i, item in ipairs(items or {}) do parts[i] = item.text end
    return table.concat(parts)
end

function M.serialize_items(items)
    local rows = {}
    for _, item in ipairs(items or {}) do
        local parts = item.parts or {}
        rows[#rows + 1] = table.concat({
            item.text or "",
            parts.s or "",
            parts.y or "",
            parts.p or "",
            parts.code or "",
        }, "\t")
    end
    return table.concat(rows, "\n")
end

function M.deserialize_items(text)
    local items = {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local ch, s, y, p, code = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        if ch and ch ~= "" then
            local parts = nil
            if s ~= "" and y ~= "" and p ~= "" then
                parts = { s = s, y = y, p = p, code = code ~= "" and code or (s .. y .. p) }
            end
            items[#items + 1] = { text = ch, parts = parts }
        end
    end
    return items
end

return M
