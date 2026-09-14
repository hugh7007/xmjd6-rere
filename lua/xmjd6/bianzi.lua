-- 辫子模式：按绑定键（当前为 |）把当前首选用 ᥬ ᩤ 包裹后上屏
local kAccepted = 1
local kNoop = 2

local function init(env)
    -- 绑定键在部署时读一次，避免每个按键都查询 config
    env.bind_key = env.engine.schema.config:get_string('key_binder/bian_zi')
    -- [0914] 键盘上 | 是 Shift+\，实际事件 repr 为 "Shift+bar"（带 Shift 修饰），
    --   原 key:repr() == "bar" 永远不匹配 → 辫子模式从未被触发。
    --   改为兼容：repr 相等，或 keycode == 0x7C 且仅带 Shift（屏蔽 Ctrl/Alt/Super）。
    env.bind_keycode = (env.bind_key == "bar") and 0x7C or nil
end

local function match_bind(key, env)
    if key:repr() == env.bind_key then
        return true
    end
    if env.bind_keycode and key.keycode == env.bind_keycode
        and not key:ctrl() and not key:alt() and not key:super() then
        return true
    end
    return false
end

local function bianzi(key, env)
    if not env.bind_key or key:release() or not match_bind(key, env) then
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
