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
-- 排除表：命中时上屏保留 i 前缀（如 ima → 上屏 ima，而非 ma）。
--   排除表逻辑在 eng_quick_exclude 公共模块中，两个文件共用。
--   空格/回车均通过 keycode 判断，兼容手机端。
--
-- 含汉字的 i 码（io/ii/iu/ia …）：空格与回车一律不拦截，
--   交回主词典的选字/顶功流程，否则会被上屏成 i+码 的字面量。

local M = {}

local kAccepted = 1
local kNoop = 2

local PREFIX = "i"
local SEP = "'"

-- keycode 常量（跨平台）
local KEY_SPACE = 32    -- 0x20
local KEY_RETURN = 13   -- 0x0d

local exclude = require("xmjd6/eng_quick_exclude")

local function to_commit(input)
    if not input or input == "" then return "" end
    local s = input
    if s:sub(1, #PREFIX) == PREFIX then
        s = s:sub(#PREFIX + 1)
    end
    s = s:gsub(SEP .. "$", "")
    return s:gsub(SEP, " ")
end

local function is_eng_quick_input(input)
    return input and #input >= #PREFIX + 1 and input:sub(1, #PREFIX) == PREFIX
end

local function is_valid_query(query)
    return query and query:match("^[%a']+$") ~= nil
end

-- 判断是否空格键（兼容 repr 和 keycode）
local function is_space(key)
    local repr = key:repr()
    if repr == "space" then return true end
    -- fallback: keycode 32
    local ok, code = pcall(key.keycode, key)
    if ok and code == KEY_SPACE then return true end
    return false
end

-- 判断是否回车键（兼容 repr 和 keycode）
local function is_return(key)
    local repr = key:repr()
    if repr == "Return" or repr == "Lock+Return" then return true end
    local ok, code = pcall(key.keycode, key)
    if ok and code == KEY_RETURN then return true end
    return false
end

local function processor(key, env)
    if not key or (key.release and key:release()) then
        return kNoop
    end
    if key:ctrl() or key:alt() or key:super() then
        return kNoop
    end

    local is_sp = is_space(key)
    local is_ret = is_return(key)
    if not is_sp and not is_ret then
        return kNoop
    end

    local ctx = env.engine.context
    local input = ctx.input or ""

    if not is_eng_quick_input(input) then
        return kNoop
    end

    local query = input:sub(#PREFIX + 1)
    if not is_valid_query(query) then
        return kNoop
    end

    -- 含汉字的 i 码（io→金钅⺗㣺、ii→〢艹刂、iu→扌手リ）：不拦截，交给主词典
    if exclude.is_pass_through(query) then
        return kNoop
    end

    -- 排除表：命中时空格和回车都直接上屏 i + 排除词
    if exclude.is_excluded(query) then
        local clean_query = query:gsub(SEP .. "$", "")
        local text = PREFIX .. clean_query:gsub(SEP, " ")
        env.engine:commit_text(text)
        ctx:clear()
        return kAccepted
    end

    if is_sp then
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

    if is_ret then
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
