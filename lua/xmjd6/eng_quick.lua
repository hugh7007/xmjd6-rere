-- eng_quick.lua
-- i 前缀快捷英文字母输入模式（无词库，纯字母上屏）。
-- translator 部分：在 eng_quick_mode 分段内生成候选。
--
-- affix_segmentor@eng_quick_mode 会去掉 i 前缀，translator 收到的 input 不含 i。
-- 例如用户输入 itea → 分段 input 为 tea → 候选显示 tea
-- 用户输入 igood'tea → 分段 input 为 good'tea → 候选显示 good tea
--
-- i 空码不触发 affix_segmentor（prefix 后需有内容），留给 repeat_history。

local M = {}

local SEP = "'"

local function to_display(input)
    if not input or input == "" then return "" end
    -- 去掉末尾的分隔符，避免显示末尾多余空格
    local s = input:gsub(SEP .. "$", "")
    return s:gsub(SEP, " ")
end

local function is_valid_query(query)
    return query and query:match("^[%a']+$") ~= nil
end

local function translator(input, seg, env)
    -- 只在 eng_quick_mode 分段中生效
    if not seg:has_tag("eng_quick_mode") then
        return
    end

    if not is_valid_query(input) then
        return
    end

    local display = to_display(input)
    if display == "" then return end

    local cand = Candidate("eng_quick", seg.start, seg._end, display, "")
    cand.quality = 10000
    cand.preedit = display
    yield(cand)
end

M.func = translator

return M
