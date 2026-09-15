-- 辫子模式：按绑定键（当前为 |）把当前首选用 ᥬ ᩤ 包裹后上屏
local kAccepted = 1
local kNoop = 2

-- [0914] 绑定键 "bar" 的两种实际来源都要接住：
--   ① 桌面键盘 | 是 Shift+\，事件 repr 为 "Shift+bar"（带 Shift 修饰），keycode = 0x7C；
--   ② iOS Hamster 皮肤 N 键下滑（swipeDownAction）[0914 起输出全角 ｜]，合成事件 keycode = 0xFF5C。
--   原 key:repr() == "bar" 永远匹配不上 → 辫子模式从未被触发。
local BIND_KEYCODES = { [0x7C] = true, [0xFF5C] = true } -- "|" 与 "｜"

local function init(env)
    -- 绑定键在部署时读一次，避免每个按键都查询 config
    env.bind_enabled = (env.engine.schema.config:get_string('key_binder/bian_zi') == 'bar')
end

local function match_bind(key, env)
    if not env.bind_enabled then
        return false
    end
    if BIND_KEYCODES[key.keycode]
        and not key:ctrl() and not key:alt() and not key:super() then
        return true
    end
    return false
end

local function bianzi(key, env)
    if not env.bind_enabled or key:release() or not match_bind(key, env) then
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
