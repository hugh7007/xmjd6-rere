-- 补全候选过滤器（Completion Filter）
-- 功能：根据开关控制是否显示编码补全候选词
-- 特点：
--   1. 支持动态开关（completion）监听
--   2. 优化内存管理，正确断开监听器防止泄漏
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-01-25

return {
    -- 初始化函数
    init = function(env)
        local ctx = env.engine.context

        -- 读取当前开关状态，避免硬编码
        env.completion_enabled = ctx:get_option("completion")
        if env.completion_enabled == nil then
            env.completion_enabled = false  -- 默认关闭
        end

        -- 定义选项更新回调函数
        -- 注意：不要在闭包中捕获 ctx，避免循环引用
        local handler = function(context, opname)
            if opname == "completion" then
                env.completion_enabled = context:get_option(opname)
            end
        end

        -- 注册监听器（保存引用供 fini 断开，防止内存泄漏）
        env._completion_handler = handler
        ctx.option_update_notifier:connect(handler)
    end,

    -- 候选词过滤函数
    func = function(input, env)
        for cand in input:iter() do
            -- 补全功能关闭时，跳过所有 completion 类型的候选
            -- 使用 return 直接终止处理，提升性能
            if not env.completion_enabled and cand.type == "completion" then
                return
            end
            yield(cand)
        end
    end,

    -- 清理函数
    fini = function(env)
        -- 断开监听器，防止内存泄漏
        if env._completion_handler then
            pcall(function()
                env.engine.context.option_update_notifier:disconnect(env._completion_handler)
            end)
            env._completion_handler = nil
        end
        env.completion_enabled = nil
        collectgarbage("step", 1)
    end
}
