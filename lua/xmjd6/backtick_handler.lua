-- backtick_handler.lua
-- 当输入恰好是单个反引号 ` 时：
--   空格 → 上屏全角 ｀
--   回车 → 上屏半角 `
-- 其他情况（`b、b`、`` 等）一律放行，不影响反查/顶功等正常流程。

local M = {}

local kAccepted = 1
local kNoop = 2

local KEY_SPACE = 32
local KEY_RETURN = 13

local function is_space(key)
    if key:repr() == "space" then return true end
    local ok, code = pcall(key.keycode, key)
    if ok and code == KEY_SPACE then return true end
    return false
end

local function is_return(key)
    local repr = key:repr()
    if repr == "Return" or repr == "Lock+Return" then return true end
    local ok, code = pcall(key.keycode, key)
    if ok and code == KEY_RETURN then return true end
    return false
end

local function processor(key, env)
    if key:release() then return kNoop end
    if key:ctrl() or key:alt() or key:super() or key:shift() then return kNoop end

    local is_sp = is_space(key)
    local is_ret = is_return(key)
    if not is_sp and not is_ret then return kNoop end

    local ctx = env.engine.context
    local input = ctx.input or ""

    -- 仅当输入恰好是单个反引号时拦截
    if input ~= "`" then return kNoop end

    if is_sp then
        env.engine:commit_text("｀")
        ctx:clear()
        return kAccepted
    end

    if is_ret then
        env.engine:commit_text("`")
        ctx:clear()
        return kAccepted
    end

    return kNoop
end

M.func = processor

return M
