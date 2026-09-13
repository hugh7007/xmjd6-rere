-- help_panel.lua
-- =? / ojd 功能帮助面板的快捷操作 processor：
--   = 或 .   → 下一页；- 或 ,  → 上一页（翻页键在面板内被本处理器吞掉，
--             不再依赖 key_binder —— direct_ascii 的符号直上屏排在 key_binder 之前，
--             原生 Page_Up/Page_Down 绑定在这个面板里到不了位）
--   空格      → 执行当前高亮帮助项对应的功能（把输入串替换为该项触发码）
--   数字 1~5  → 执行当页第 N 项对应的功能
--
-- 翻页实现：页面状态编码在输入串尾（base + 若干个 =，净页偏 = 页码-1），
-- 改写输入串触发重新翻译，xmjd6_tools.lua 按页切片输出候选。
-- base = =? 或 ojd；只依赖 ctx.input 赋值（text_transform.lua 先例），
-- pcall 失败回退 ctx:clear() + ctx:push_input()。
--
-- 仅当输入串匹配 ^(=?|ojd)[-=]*$ 时接管按键，其余一律放行；
-- 文档型条目（help_items.lua 中无触发码）不接管，保持原生「上屏说明文字」行为。
--
-- 挂载位置（xmjd6.schema.yaml / engine/processors）：key_counter 之后——
--   早于 direct_ascii / quick_symbol / punctuator 等，保证 =/-/,/. 与空格数字最先到达。

local kAccepted = 1
local kNoop = 2

local help = require("xmjd6.help_items")

local M = {}

local KEY_SPACE = 0x20
local PAGE_UP_KEYS = { [0x2D] = true, [0x2C] = true }   -- - 和 ,
local PAGE_DOWN_KEYS = { [0x3D] = true, [0x2E] = true } -- = 和 .

local function digit_of(keycode)
    if keycode >= 49 and keycode <= 57 then          -- 主键盘 '1'..'9'
        return keycode - 48
    end
    if keycode >= 0xffb1 and keycode <= 0xffb9 then  -- 小键盘 KP_1..KP_9
        return keycode - 0xffb0
    end
    return nil
end

-- 解析面板状态：返回 base（=? 或 ojd）与净页偏（#= − #-）；非面板输入返回 nil
local function panel_state(input)
    input = tostring(input or "")
    local base, marks = input:match("^(=%?)([-=]*)$")
    if not base then
        base, marks = input:match("^(ojd)([-=]*)$")
    end
    if not base then
        return nil
    end
    local _, n_eq = marks:gsub("=", "")
    local _, n_minus = marks:gsub("%-", "")
    return base, n_eq - n_minus
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

local function page_size(env)
    if env.help_page_size then
        return env.help_page_size
    end
    local n = 5
    pcall(function()
        local v = env.engine.schema.config:get_int("menu/page_size")
        if v and v > 0 then
            n = v
        end
    end)
    env.help_page_size = n
    return n
end

local function total_pages(env)
    return math.ceil(#help.items / page_size(env))
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

-- 执行菜单第 n 行（1 基）对应的帮助条目：有触发码 → 替换输入串并返回 true
local function execute_row(ctx, seg, n)
    if not seg then
        return false
    end
    local cand = candidate_at(seg, n - 1)
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
    env.help_page_size = nil -- 首次按键时从配置读
end

function M.func(key, env)
    if key:release() then
        return kNoop
    end
    local ctx = env.engine.context
    if not ctx then
        return kNoop
    end
    local base, offset = panel_state(ctx.input)
    if not base then
        return kNoop
    end

    local ps = page_size(env)
    local pages = total_pages(env)

    -- 翻页：=/. 下一页，-/, 上一页；页偏编码进输入串（统一归一化为若干个 =）
    if PAGE_UP_KEYS[key.keycode] or PAGE_DOWN_KEYS[key.keycode] then
        local dir = PAGE_DOWN_KEYS[key.keycode] and 1 or -1
        local off = offset + dir
        if off < 0 then off = 0 end
        if off > pages - 1 then off = pages - 1 end
        if off ~= offset then
            replace_input(ctx, base .. string.rep("=", off))
        end
        return kAccepted
    end

    -- 数字 1~页大小：执行当页第 N 行
    local digit = digit_of(key.keycode)
    if digit then
        if digit > ps then
            return kNoop -- 当页没有该序号，保持原生行为
        end
        if execute_row(ctx, active_seg(ctx), digit) then
            return kAccepted
        end
        return kNoop -- 文档型 / 越界 → 原生「选中并上屏说明文字」
    end

    -- 空格：执行高亮项
    if key.keycode == KEY_SPACE then
        local seg = active_seg(ctx)
        if seg then
            local sel = highlighted_index(seg)
            if sel < 0 then sel = 0 end
            if execute_row(ctx, seg, sel + 1) then
                return kAccepted
            end
        end
        return kNoop
    end

    return kNoop
end

function M.fini(env)
end

return M
