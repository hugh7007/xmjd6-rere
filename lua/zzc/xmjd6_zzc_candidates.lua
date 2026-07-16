-- 天行键 自造词候选访问模块
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-10

local M = {}

function M.menu_candidate_at(menu, index)
    if not menu then return nil end
    local ok, cand = pcall(function() return menu:get_candidate_at(index) end)
    if not ok then return nil end
    return cand
end

function M.first_candidate(ctx)
    if not ctx or not ctx.composition or ctx.composition:empty() then return nil end
    local seg = ctx.composition:back()
    return M.menu_candidate_at(seg and seg.menu, 0)
end

function M.selected_candidate(ctx)
    if not ctx or not ctx.has_menu or not ctx:has_menu() then return nil end
    local ok, cand = pcall(function() return ctx:get_selected_candidate() end)
    return ok and cand or nil
end

function M.first_real_candidate(ctx, is_real_candidate, limit)
    if not ctx or not ctx.composition or ctx.composition:empty() then return nil end
    local seg = ctx.composition:back()
    local menu = seg and seg.menu
    if not menu then return nil end
    for index = 0, (limit or 10) - 1 do
        local cand = M.menu_candidate_at(menu, index)
        if not cand then break end
        if is_real_candidate(cand) then return cand end
    end
    return nil
end

function M.current_action_candidate(ctx, is_real_candidate)
    local cand = M.selected_candidate(ctx)
    if is_real_candidate(cand) then return cand end
    return M.first_real_candidate(ctx, is_real_candidate)
end

return M
