-- 辫子模式：按绑定键（当前为 |）把当前首选用 ᥬ ᩤ 包裹后上屏
local kAccepted = 1
local kNoop = 2

local function init(env)
    -- 绑定键在部署时读一次，避免每个按键都查询 config
    env.bind_key = env.engine.schema.config:get_string('key_binder/bian_zi')
end

local function bianzi(key, env)
    if not env.bind_key or key:repr() ~= env.bind_key then
        return kNoop
    end

    local context = env.engine.context
    if not context:has_menu() then
        return kNoop
    end

    local candidate = context:get_selected_candidate()
    if candidate and candidate.text and candidate.text ~= '' then
        env.engine:commit_text("ᥬ" .. candidate.text .. "ᩤ")
        context:clear()
        return kAccepted
    end

    return kNoop
end

return { init = init, func = bianzi }
