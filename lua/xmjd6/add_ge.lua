-- 加"个"模式：按绑定键（默认 \）把当前首选第一个字后插入"个"再上屏
local kAccepted = 1
local kNoop = 2

local function handle(t)
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

local function init(env)
    -- 绑定键在部署时读一次，避免每个按键都查询 config
    env.bind_key = env.engine.schema.config:get_string('key_binder/add_ge')
end

local function add_ge(key, env)
    if not env.bind_key or key:repr() ~= env.bind_key then
        return kNoop
    end

    local context = env.engine.context
    if not context:has_menu() then
        return kNoop
    end

    local candidate = context:get_selected_candidate()
    if candidate and candidate.text and candidate.text ~= '' then
        env.engine:commit_text(handle(candidate.text))
        context:clear()
        return kAccepted
    end

    return kNoop
end

return { init = init, func = add_ge }
