-- dict_search.lua
-- 当 input 形如 "字母+?"（dict_search tag）时，读取全局状态里 dict_search_trigger 准备好的搜索结果，作为候选输出

local function dict_search(input, seg, env)
    if not seg:has_tag("dict_search") then return end

    local state = _G.__dict_search_state
    if not state or not state.candidates then return end

    for i, m in ipairs(state.candidates) do
        local cand = Candidate("dict", seg.start, seg._end, m.text, m.code)
        cand.quality = 99999 - i
        yield(cand)
    end
end

return dict_search
