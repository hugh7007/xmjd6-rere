-- txjx smartTwo 快选模块，此版本经过二次优化 来源：@浮生 https://github.com/wzxmer/rime-txjx
-- 常量
local kAccepted = 1
local kNoop = 2

local semicolon = "semicolon"
local apostrophe = "apostrophe"

local function processor(key_event, env)
    if key_event:release() or key_event:alt() or key_event:super() then
        return kNoop
    end
    local key = key_event:repr()
    if key ~= semicolon and key ~= apostrophe then
        return kNoop
    end

    local context = env.engine.context
    -- 添加边界检查，防止 composition:back() 返回 nil
    local comp = context.composition:back()
    if not comp then return kNoop end
    
    -- 防止 page_size 为 0 导致除零错误
    local page_size = env.engine.schema.page_size or 5
    if page_size == 0 then page_size = 5 end
    
    local selected_index = comp.selected_index
    local page_start = math.floor(selected_index / page_size) * page_size

    local index = key == semicolon and 1 or 2
    if context:select(page_start + index) then
        context:commit()
        return kAccepted
    end

    if not context:get_selected_candidate() then
        if #context.input <= 1 then
            -- 分号引导的符号需要交给下一个处理器
            return kNoop
        end
        context:clear()
    else
        context:commit()
    end

    return kAccepted
end

local function fini(env)
    collectgarbage("step", 1)
end

return { func = processor, fini = fini }