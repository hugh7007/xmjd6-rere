-- Rime 通用 GC 节流器：热路径用增量 step，释放大对象或退出时再 full collect
-- 适用于所有 Rime 方案，直接复制即可使用
--
-- 配置参数（传入 init 的表）：
--   step_every ：累计多少"计数"触发一次增量 GC（0 表示关闭，默认 50）
--   step_k     ：增量 GC 强度，数字越小越轻量（默认 1）
--   weight     ：tick 默认权重（默认 10）；也可在 tick 调用时单独传入
--
-- 使用示例：
--   local gc = require("方案名.gc")
--
--   function init(env)
--       gc.init(env, { step_every = 50, step_k = 1, weight = 10 })
--   end
--
--   function func(input, env)
--       -- 处理逻辑...
--       gc.tick(env, 10)  -- 高频路径：增量 GC
--   end
--
--   function fini(env)
--       gc.full(env)  -- 退出时：完整 GC
--       gc.fini(env)  -- 清理状态
--   end
--
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-01-25

local M = {}

-- 初始化 GC 管理器
-- @param env 环境对象
-- @param opt 配置表 { step_every, step_k, weight }
function M.init(env, opt)
    env._gc_state = { n = 0, last_full = 0 }
    env._gc_opt = opt or { step_every = 50, step_k = 1, weight = 10 }
end

-- 增量 GC 计数器，达到阈值时触发轻量 GC
-- @param env 环境对象
-- @param weight 本次计数权重（可选，默认使用 opt.weight）
function M.tick(env, weight)
    local st = env._gc_state
    -- 自动恢复：如果状态被清理，重新初始化
    if not st then
        M.init(env, env._gc_opt)
        st = env._gc_state
    end
    if not st then return end

    local opt = env._gc_opt or {}
    st.n = st.n + (weight or opt.weight or 1)
    local every = opt.step_every or 0
    if every > 0 and st.n >= every then
        collectgarbage("step", opt.step_k or 1)
        st.n = 0
    end
end

-- 执行完整 GC，用于释放大对象或退出时清理
-- @param env 环境对象
function M.full(env)
    pcall(function()
        collectgarbage("collect")
        if env._gc_state then
            env._gc_state.last_full = os.time()
            env._gc_state.n = 0
        end
    end)
end

-- 清理 GC 管理器状态，在 fini 中调用
-- @param env 环境对象
function M.fini(env)
    -- 不清理 GC 状态，保留配置供下次自动恢复使用
    -- env._gc_state = nil
    -- env._gc_opt = nil
end

return M
