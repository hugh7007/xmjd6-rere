-- eng_quick.lua
-- i 前缀快捷英文字母输入模式（无词库，纯字母上屏）。
-- translator 部分：在 eng_quick_mode 分段内生成候选。
--
-- affix_segmentor@eng_quick_mode 会去掉 i 前缀，translator 收到的 input 不含 i。
-- 例如用户输入 itea → 分段 input 为 tea → 候选显示 tea
-- 用户输入 igood'tea → 分段 input 为 good'tea → 候选显示 good tea
--
-- 排除表：命中时候选显示保留 i 前缀（如 input=ma → 候选显示 ima）。
--   排除表逻辑在 eng_quick_exclude 公共模块中，两个文件共用。

local M = {}

local SEP = "'"
local PREFIX = "i"

local exclude = require("xmjd6/eng_quick_exclude")

local function to_display(input)
    if not input or input == "" then return "" end
    local s = input:gsub(SEP .. "$", "")
    return s:gsub(SEP, " ")
end

local function is_valid_query(query)
    return query and query:match("^[%a']+$") ~= nil
end

local function translator(input, seg, env)
    if not seg:has_tag("eng_quick_mode") then
        return
    end

    if not is_valid_query(input) then
        return
    end

    local display = to_display(input)
    if display == "" then return end

    -- 排除表：命中时候选显示 i + 排除词
    if exclude.is_excluded(input) then
        local full = PREFIX .. display
        local cand = Candidate("eng_quick", seg.start, seg._end, full, "")
        cand.quality = 10000
        cand.preedit = full
        yield(cand)
        return
    end

    local cand = Candidate("eng_quick", seg.start, seg._end, display, "")
    cand.quality = 10000
    cand.preedit = display
    yield(cand)
end

M.func = translator

return M
