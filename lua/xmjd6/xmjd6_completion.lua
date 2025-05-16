-- 优化版completion 来源：@浮生 https://github.com/wzxmer/rime-txjx
-- 补全过滤器模块
-- 用于控制是否显示编码补全候选词

-- 初始化开关状态为关闭
local enabled = false

return {
    -- 初始化函数
    init = function(env)
        -- 定义选项更新回调函数
        local handler = function(ctx, opname)
            -- 当"completion"选项发生变化时更新状态
            if opname == "completion" then
                enabled = ctx:get_option(opname)
            end
        end
        -- 注册选项更新监听器
        env.engine.context.option_update_notifier:connect(handler)
    end,
    
    -- 候选词处理函数
    func = function(input, env)
        -- 遍历所有候选词
        for cand in input:iter() do
            -- 如果补全功能关闭且候选词类型是补全词
            if not enabled and cand.type == "completion" then
                -- 终止处理，丢弃后续所有候选词
                return
            end
            -- 正常返回候选词
            yield(cand)
        end
    end,
    
    -- 清理函数（空实现）
    fini = function() end
}
