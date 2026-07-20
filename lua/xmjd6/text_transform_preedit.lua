local SOURCE_PROPERTY = "xmjd6_text_transform_source"

local function filter(input, env)
    local context = env and env.engine and env.engine.context
    local source = ""
    if context and type(context.get_property) == "function" then
        local ok, value = pcall(function() return context:get_property(SOURCE_PROPERTY) end)
        if ok then source = tostring(value or "") end
    end

    for cand in input:iter() do
        if source ~= "" and cand.type == "text_transform" then
            cand.preedit = source
        end
        yield(cand)
    end
end

return filter
