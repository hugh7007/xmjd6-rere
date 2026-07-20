-- eng_quick_processor.lua
-- i 前缀快捷英文字母输入模式（无词库，纯字母上屏）。
-- processor 部分：拦截空格和回车。
--
-- 行为：
--   i + good + 空格 → 空格作为单词分隔符，追加 ' 继续输入（igood'）
--   双空格          → 上屏整句（good tea）
--   回车            → 上屏整句（good tea）
--   i 空码          → 不拦截，express_editor 上屏 i 字母
--
-- 注意：context.input 包含 i 前缀（如 igood'tea），上屏时需去掉 i 前缀和末尾分隔符。

local M = {}

local kAccepted = 1
local kNoop = 2

local PREFIX = "i"
local SEP = "'"

local function to_commit(input)
    if not input or input == "" then return "" end
    -- 去掉 i 前缀
    local s = input
    if s:sub(1, #PREFIX) == PREFIX then
        s = s:sub(#PREFIX + 1)
    end
    -- 去掉末尾的分隔符
    s = s:gsub(SEP .. "$", "")
    -- 分隔符转空格
    return s:gsub(SEP, " ")
end

local function is_eng_quick_input(input)
    -- input 以 i 开头且后面有内容
    return input and #input >= #PREFIX + 1 and input:sub(1, #PREFIX) == PREFIX
end

local function is_valid_query(query)
    -- 去掉 i 前缀后的部分，允许纯字母或字母+分隔符+字母
    return query and query:match("^[%a']+$") ~= nil
end

local function processor(key, env)
    if not key or (key.release and key:release()) then
        return kNoop
    end
    if key:ctrl() or key:alt() or key:super() then
        return kNoop
    end

    local repr = key:repr()
    if repr ~= "space" and repr ~= "Return" and repr ~= "Lock+Return" then
        return kNoop
    end

    local ctx = env.engine.context
    local input = ctx.input or ""

    -- 不处理空码 i（留给 repeat_history / express_editor）
    if not is_eng_quick_input(input) then
        return kNoop
    end

    local query = input:sub(#PREFIX + 1)
    if not is_valid_query(query) then
        return kNoop
    end

    if repr == "space" then
        local last_char = input:sub(-1)
        if last_char == SEP then
            -- 双空格：上屏整句
            local text = to_commit(input)
            if text and text ~= "" then
                env.engine:commit_text(text)
                ctx:clear()
                return kAccepted
            end
            return kNoop
        else
            -- 单空格：追加分隔符
            ctx.input = input .. SEP
            return kAccepted
        end
    end

    if repr == "Return" or repr == "Lock+Return" then
        local text = to_commit(input)
        if text and text ~= "" then
            env.engine:commit_text(text)
            ctx:clear()
            return kAccepted
        end
        return kNoop
    end

    return kNoop
end

M.func = processor

return M
