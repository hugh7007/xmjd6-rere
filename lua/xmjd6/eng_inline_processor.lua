-- eng_inline_processor.lua
-- 配合 eng_inline.lua 使用。
-- 拦截回车键：当 input 以 i 前缀引导英文输入时，回车与空格行为一致——上屏首选候选文本。
-- 没有 i 前缀或无候选时，回车走 express_editor 原始逻辑（上屏原始编码）。

local M = {}

local kAccepted = 1
local kNoop = 2

local function processor(key, env)
    if key:release() or key:ctrl() or key:alt() or key:super() then
        return kNoop
    end

    -- 只拦截回车键
    local repr = key:repr()
    if repr ~= "Return" and repr ~= "Lock+Return" then
        return kNoop
    end

    local context = env.engine.context
    local input = context.input or ""

    -- 只处理 i 前缀 + 字母的情况
    if #input < 2 or input:sub(1, 1) ~= "i" then
        return kNoop
    end

    local query = input:sub(2)
    if not query:match("^[a-zA-Z]+$") then
        return kNoop
    end

    -- 必须有候选才拦截
    local cand = context:get_selected_candidate()
    if not cand then
        return kNoop
    end

    -- 上屏候选文本（不含 i 前缀）
    env.engine:commit_text(cand.text)
    context:clear()
    return kAccepted
end

M.func = processor

return M
