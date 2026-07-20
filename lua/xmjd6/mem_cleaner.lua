-- mem_cleaner.lua
-- 可释放缓存的全局注册表。
-- 各脚本把"清空自己缓存"的回调注册进来；iOS 端键盘收起时发送
-- CLEAR_CACHE_KEYCODE（由 dict_search_trigger 接收），统一调用 release_all()
-- 一次性释放所有 Lua 缓存并触发 GC。
--
-- 用法：
--   local mem_cleaner = require("xmjd6.mem_cleaner")
--   -- 组件实例（env 级）缓存，init 注册、fini 注销：
--   env.mem_release = mem_cleaner.register(function()
--       env.some_cache = nil
--   end)
--   mem_cleaner.unregister(env.mem_release)  -- fini 中调用，避免持有失效 env
--   -- 模块级缓存注册一次即可，无需注销。

local M = { releasers = {} }

-- 注册一个释放回调，返回值作为注销凭据
function M.register(fn)
    if type(fn) == "function" then
        M.releasers[fn] = true
    end
    return fn
end

function M.unregister(fn)
    if fn then
        M.releasers[fn] = nil
    end
end

-- 释放所有已注册缓存并做一次全量 GC
function M.release_all()
    for fn in pairs(M.releasers) do
        pcall(fn)
    end
    collectgarbage("collect")
end

return M
