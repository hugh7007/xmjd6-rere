-- 候选处理工具
-- 封装候选 genuine/comment/type 访问与安全修改。
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-29

local M = {}

local type = type

function M.safe_genuine(cand)
    if not cand or not cand.get_genuine then return cand end
    local ok, genuine = pcall(function()
        return cand:get_genuine()
    end)
    if ok and genuine then return genuine end
    return cand
end

function M.set_comment(cand, comment)
    local genuine = M.safe_genuine(cand)
    if genuine then
        genuine.comment = comment or ""
        return true
    end
    return false
end

function M.append_comment(cand, suffix)
    if not suffix or suffix == "" then return true end
    return M.set_comment(cand, (cand.comment or "") .. suffix)
end

function M.merge_pron_comment(pron, comment)
    comment = comment or ""
    if comment:find(" | ", 1, true) then return comment end
    if comment:match("^%[.*%]$") then
        return "[" .. pron .. " | " .. comment:sub(2, -2) .. "]"
    end
    if comment ~= "" then
        return "[" .. pron .. " | " .. comment .. "]"
    end
    return "[" .. pron .. "]"
end

function M.has_reading(comment)
    if type(comment) ~= "string" then return false end
    return comment:match("%(([^)]+)%)") ~= nil or comment:match("（([^）]+)）") ~= nil
end

function M.utf8_len(text)
    if type(text) ~= "string" then return nil end
    return utf8.len(text)
end

function M.wrap_append(cand, suffix)
    if not cand or not suffix or suffix == "" then return cand end
    local text = (cand.text or "") .. suffix
    local ok, nc = pcall(Candidate, cand.type or "append", cand.start, cand._end, text, cand.comment or "")
    if not ok or not nc then return cand end
    nc.preedit = text
    nc.quality = cand.quality
    return nc
end

function M.genuine_text(cand)
    local text = cand and cand.text or ""
    local genuine = M.safe_genuine(cand)
    if genuine and genuine.text then text = genuine.text end
    return text
end

return M
