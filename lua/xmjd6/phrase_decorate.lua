-- phrase_decorate.lua
-- 绑定键"装饰首选后上屏"processor 合集（合并自 add_ge.lua / bianzi.lua）
--
-- 两个 processor 结构完全同构：
--   init 读一次绑定键 → 匹配绑定键 → 取当前首选 → 加工文本 → commit + clear
-- 只是加工方式不同（插入「个」/ 用 ᥬᩤ 包裹），且各自绑定键与开关独立配置，
-- 因此合并后仍保留各自独立的 init 分支，语义完全不变。
--
-- 挂载：
--   - lua_processor@*xmjd6/phrase_decorate@add_ge   # 键位 key_binder/add_ge
--   - lua_processor@*xmjd6/phrase_decorate@bianzi   # 键位 key_binder/bian_zi（值须为 bar）
--
-- 注意：librime-lua 不会在挂载时为每个实例调用不同函数；init 是靠 @name_space
-- 拿不到的（init 无 env.name_space 保证）。因此这里让 init 同时初始化两份配置，
-- 再由 .func 按 keycode/repr 分派——两个绑定键本来就互不重叠，行为与原来一致。

local kAccepted = 1
local kNoop = 2

-- =====================================================================
-- 第一部分：add_ge（原 add_ge.lua）
-- 按绑定键（默认 \）把当前首选第一个字后插入「个」再上屏
-- =====================================================================
local function add_ge_handle(t)
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

-- =====================================================================
-- 第二部分：bianzi（原 bianzi.lua）
-- 按绑定键（当前为 |）把当前首选用 ᥬ ᩤ 包裹后上屏
-- =====================================================================
-- [0914] 绑定键 "bar" 的两种实际来源都要接住：
--   ① 桌面键盘 | 是 Shift+\，事件 repr 为 "Shift+bar"（带 Shift 修饰），keycode = 0x7C；
--   ② iOS Hamster 皮肤 N 键下滑（swipeDownAction）[0914 起输出全角 ｜]，合成事件 keycode = 0xFF5C。
--   原 key:repr() == "bar" 永远匹配不上 → 辫子模式从未被触发。
local BIANZI_BIND_KEYCODES = { [0x7C] = true, [0xFF5C] = true } -- "|" 与 "｜"

-- =====================================================================
-- init：一次读齐两份配置
-- =====================================================================
local function init(env)
    -- 绑定键在部署时读一次，避免每个按键都查询 config
    env.add_ge_key = env.engine.schema.config:get_string('key_binder/add_ge')
    env.bianzi_enabled = (env.engine.schema.config:get_string('key_binder/bian_zi') == 'bar')
end

local function bianzi_match_bind(key, env)
    if not env.bianzi_enabled then
        return false
    end
    if BIANZI_BIND_KEYCODES[key.keycode]
        and not key:ctrl() and not key:alt() and not key:super() then
        return true
    end
    return false
end

-- =====================================================================
-- processor：按绑定键分派到两个装饰逻辑
-- =====================================================================
local function processor(key, env)
    if key:release() then
        return kNoop
    end

    local is_add_ge = env.add_ge_key and key:repr() == env.add_ge_key
    local is_bianzi = bianzi_match_bind(key, env)
    if not is_add_ge and not is_bianzi then
        return kNoop
    end

    local context = env.engine.context
    if not context:has_menu() then
        return kNoop
    end

    local candidate = context:get_selected_candidate()
    if not (candidate and candidate.text and candidate.text ~= '') then
        return kNoop
    end

    if is_add_ge then
        env.engine:commit_text(add_ge_handle(candidate.text))
    else
        env.engine:commit_text("ᥬ" .. candidate.text .. "ᩤ")
    end
    context:clear()
    return kAccepted
end

return { init = init, func = processor }
