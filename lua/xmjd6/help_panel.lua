-- help_panel.lua
-- =? 功能帮助面板的快捷操作 processor：
--   空格      → 执行当前高亮帮助项对应的功能（把输入串替换为该项触发码）
--   数字 1~9  → 执行当前页第 N 项对应的功能（当页 = 高亮项所在页）
-- 仅当输入串恰为 =? 时接管按键，其余一律放行；
-- 文档型条目（help_items.lua 中无触发码）不接管，保持原生「上屏说明文字」行为。
-- 翻页仍用原生 key_binder 绑定：- = Page_Up / Page_Down（xmjd6.schema.yaml key_binder）。
--
-- API 均用本方案已有先例（o_number_select.lua / candidate_order_processor.lua / text_transform.lua）：
--   ctx.composition:back() → seg；seg.selected_index（0 基属性）；seg:get_candidate_at(i)（0 基）
--   ctx.input = text（单次更新替换输入串）；回退 ctx:clear() + ctx:push_input(text)
--
-- 挂载位置（xmjd6.schema.yaml / engine/processors）：key_counter 之后——
--   早于 direct_ascii / topup / selector，保证空格与数字最先到达本处理器；
--   早挂 + 「input 恰为 =?」强守卫，对其他任何状态零影响。

local kNoop = 2

local help = require("xmjd6.help_items")

local M = {}

local KEY_SPACE = 0x20

local function digit_of(keycode)
    if keycode >= 49 and keycode <= 57 then          -- 主键盘 '1'..'9'
        return keycode - 48
    end
    if keycode >= 0xffb1 and keycode <= 0xffb9 then  -- 小键盘 KP_1..KP_9
        return keycode - 0xffb0
    end
    return nil
end

-- 单次更新替换整个输入串（text_transform.lua 的做法，避免 clear+push 两次通知）
local function replace_input(ctx, text)
    local ok = pcall(function() ctx.input = text end)
    if ok and tostring(ctx.input or "") == text then
        return true
    end
    ctx:clear()
    ctx:push_input(text)
    return true
end

local function active_seg(ctx)
    local ok, comp = pcall(function() return ctx.composition:back() end)
    if ok and comp then
        return comp
    end
    return nil
end

local function highlighted_index(seg)
    local ok, idx = pcall(function() return seg.selected_index end)
    if ok and type(idx) == "number" then
        return idx
    end
    return 0
end

local function candidate_at(seg, index)
    local ok, cand = pcall(function() return seg:get_candidate_at(index) end)
    if ok then
        return cand
    end
    return nil
end

-- 执行序号（0 基）对应条目：有触发码 → 替换输入串并返回 true
local function execute_index(ctx, seg, idx0)
    local cand = candidate_at(seg, idx0)
    if not cand or cand.type ~= "tools" then
        return false
    end
    local trigger = help.trigger_of(cand.text)
    if not trigger then
        return false
    end
    replace_input(ctx, trigger)
    return true
end

function M.init(env)
    env.help_page_size = 5
    pcall(function()
        local v = env.engine.schema.config:get_int("menu/page_size")
        if v and v > 0 then
            env.help_page_size = v
        end
    end)
end

function M.func(key, env)
    if key:release() then
        return kNoop
    end
    local ctx = env.engine.context
    if not ctx or tostring(ctx.input or "") ~= "=?" then
        return kNoop
    end

    local seg = active_seg(ctx)
    if not seg then
        return kNoop
    end

    -- 空格：执行高亮项
    if key.keycode == KEY_SPACE then
        local sel = highlighted_index(seg)
        if execute_index(ctx, seg, sel) then
            return 1 -- kAccepted
        end
        return kNoop
    end

    -- 数字 1~9：执行当页第 N 项
    local digit = digit_of(key.keycode)
    if digit then
        if digit > env.help_page_size then
            return kNoop -- 当页没有该序号，保持原生行为
        end
        local sel = highlighted_index(seg)
        local page = math.floor(sel / env.help_page_size)
        local target0 = page * env.help_page_size + (digit - 1)
        if target0 < 0 then
            target0 = 0
        end
        if execute_index(ctx, seg, target0) then
            return 1 -- kAccepted
        end
        return kNoop -- 文档型 / 越界 → 原生「选中并上屏说明文字」
    end

    return kNoop
end

function M.fini(env)
end

return M
