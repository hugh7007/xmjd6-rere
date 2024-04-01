function handle(t)
    local text = t
    if utf8.len(text) > 1 then
        -- 使用 utf8.offset 来获取第一个字符的位置
        local pos = utf8.offset(text, 2) -- 返回第二个字符的位置
        -- 使用这个位置来切割字符串
        local result = string.sub(text, 1, pos - 1) .. '个' .. string.sub(text, pos)
        return result
    else
        return text
    end
end

local function add_ge(key, env)
    local engine = env.engine
    local context = engine.context
    local commit_text = context:get_commit_text()
    local config = engine.schema.config
    local bindKey = config:get_string('key_binder/add_ge')

    if context:has_menu() and context:get_selected_candidate().text ~= '' then
        if (key:repr() == bindKey) then

            local candidate = context:get_selected_candidate()
            if candidate ~= nil then
                local text = handle(candidate.text)
                engine:commit_text(text)

                context:clear()
                return 1 -- kAccepted
            end
        end
    end

    return 2 -- kNoop
end

return add_ge
