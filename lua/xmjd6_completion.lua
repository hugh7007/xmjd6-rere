-- 补全候选过滤器 + 单字优先
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-02-21
-- 功能：completion 关闭时截断补全候选；enable_sentence 关闭时对候选做单字优先排序

local utf8_len = utf8.len
local type = type

local ctx_handlers = setmetatable({}, { __mode = "k" })

return {
    init = function(env)
        local ctx = env.engine.context
        local config = env.engine.schema.config

        if env._completion_handler and ctx.option_update_notifier then
            pcall(function() ctx.option_update_notifier:disconnect(env._completion_handler) end)
        end
        ctx_handlers[ctx] = nil

        env.completion_enabled = ctx:get_option("completion")
        if env.completion_enabled == nil then env.completion_enabled = false end

        env._danzi_first = not (config:get_bool("translator/enable_sentence") or false)

        local handler = function(context, opname)
            if opname == "completion" then
                env.completion_enabled = context:get_option(opname)
            end
        end

        env._completion_handler = handler
        ctx_handlers[ctx] = handler
        ctx.option_update_notifier:connect(handler)
    end,

    func = function(input, env)
        local enabled = env.completion_enabled
        local danzi = env._danzi_first
        local buffer = {}
        local buffer_size = 0
        local comp_count = 0

        for cand in input:iter() do
            if cand.type == "completion" then
                if not enabled then break end
                comp_count = comp_count + 1
                if comp_count > 30 then break end
            end
            if not danzi then
                yield(cand)
            else
                local c = cand.comment
                if c and type(c) == "string" and #c == 0 then
                    yield(cand)
                else
                    local text_len = utf8_len(cand.text)
                    if text_len == 1 then
                        yield(cand)
                    elseif text_len and text_len > 1 then
                        buffer_size = buffer_size + 1
                        buffer[buffer_size] = cand
                    end
                end
            end
        end

        for i = 1, buffer_size do
            yield(buffer[i])
        end
    end,

    fini = function(env)
        local ctx = env.engine and env.engine.context
        if ctx and env._completion_handler then
            pcall(function() ctx.option_update_notifier:disconnect(env._completion_handler) end)
        end
        ctx_handlers[ctx] = nil
        env._completion_handler = nil
    end
}
