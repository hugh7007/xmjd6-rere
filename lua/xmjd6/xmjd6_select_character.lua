-- 优化版select_character，此版本经过二次优化 来源：@浮生 https://github.com/wzxmer/rime-txjx
-- 以词定字

local kAccepted = 1
local kNoop = 2

local select = {}

function select.init(env)
    local config = env.engine.schema.config
    env.first_key = config:get_string('key_binder/select_first_character')
    env.last_key = config:get_string('key_binder/select_last_character')
end

function select.func(key, env)
    local engine = env.engine
    local context = engine.context

    if not key:release()
        and (context:is_composing() or context:has_menu())
        and (env.first_key or env.last_key)
    then
        local text = context.input
        if context:get_selected_candidate() then
            text = context:get_selected_candidate().text
        end
        
        -- 安全检查：utf8.len 可能返回 nil
        local text_len = text and utf8.len(text)
        if text_len and text_len > 1 then
            if key:repr() == env.first_key then
                local offset = utf8.offset(text, 2)
                if offset then
                    engine:commit_text(text:sub(1, offset - 1))
                    context:clear()
                    return kAccepted
                end
            elseif key:repr() == env.last_key then
                local offset = utf8.offset(text, -1)
                if offset then
                    engine:commit_text(text:sub(offset))
                    context:clear()
                    return kAccepted
                end
            end
        end
    end
    
    return kNoop
end

function select.fini(env)
    env.first_key = nil
    env.last_key = nil
    collectgarbage("step", 1)
end

return select
