-- direct_ascii.lua
-- 空码状态下让数字和英文句点直接上屏，避免 fallback_segmentor
-- 把 2. 之类内容留在组合串中等待空格确认。
--
-- 合并自 punct_direct_processor.lua：
--   . 句号：固定直接上屏（不受开关控制）
--   = 等号：独立开关控制（equal_direct_enabled）
--   ; 分号：复用快符开关（quick_symbol_enabled）
--   & 符号：固定直接上屏（空码时），有候选时放行给 key_binder 切换 emoji_cn
--   / \ * $ ' 等符号：受符号开关控制（punct_direct_enabled）
--
-- 开关语义：
--   option = true  → 编辑模式（不直接上屏，交给后续 processor）
--   option = false → 直接上屏模式

local kAccepted = 1
local kNoop = 2

local KEY_TEXT = {
    period = ".", comma = ",", colon = ":", semicolon = ";",
    question = "?", exclam = "!", exclamation = "!",
    minus = "-", plus = "+", slash = "/", backslash = "\\",
}

-- 符号映射表（合并自 punct_direct_processor）
-- keycode = { 符号名, 半角, 全角, 开关名 }
-- 开关名为 nil 表示不受开关控制，固定直接上屏
local punct_by_keycode = {
    [0x2E] = { "period",    ".", "。", nil },                     -- . 句号（数字后输出半角，否则中文全角/英文半角）
    [0x2C] = { "comma",     ",", "，", nil },                     -- , 逗号（中文全角/英文半角）
    [0x3D] = { "equal",     "=", "=", "equal_direct_enabled" },   -- = 等号（独立开关）
    [0x3B] = { "semicolon", ";", "；", "quick_symbol_enabled" },  -- ; 分号（复用快符开关）
    [0x2F] = { "slash",     "/", "/", "punct_direct_enabled" },   -- / 斜杠
    [0x5C] = { "backslash", "\\", "、", "punct_direct_enabled" }, -- \ 反斜杠
    [0x2A] = { "asterisk",  "*", "*", "punct_direct_enabled" },   -- * 星号
    [0x26] = { "ampersand", "&", "&", nil, true },   -- & 空码直接上屏；有候选时放行给 key_binder toggle emoji_cn
    [0x24] = { "dollar",    "$", "￥", "punct_direct_enabled" },  -- $ (Shift+4)
    [0x27] = { "apostrophe","'", "'", "punct_direct_enabled" },   -- ' 单引号
}

-- 记录最近是否输入过数字（模块级状态，跨按键保持）
local last_was_number = false

local function configured_symbols(env)
    if type(env and env.symbols) == "string" then return env.symbols end
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    if config and config.get_string then
        local ok, value = pcall(function() return config:get_string("direct_ascii/symbols") end)
        if ok and type(value) == "string" then return value end
    end
    return "."
end

local function digits_enabled(env)
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    if config and config.get_bool then
        local ok, value = pcall(function() return config:get_bool("direct_ascii/digits") end)
        if ok and type(value) == "boolean" then return value end
    end
    return true
end

local function processor(key_event, env)
    if key_event:release() or key_event:ctrl() or key_event:alt() or key_event:super() then
        return kNoop
    end

    local engine = env and env.engine
    local context = engine and engine.context
    if not engine or not engine.commit_text or not context then
        return kNoop
    end

    local ch = key_event.keycode
    local input = context.input or ""

    -- 记录数字键输入（0-9），让后续符号能判断是否跟随在数字后面
    -- 注意：只有数字真正作为字符上屏时才标记 last_was_number；
    --       数字用于选重（有候选）时不标记，否则会导致选词后句号误判为半角。
    if ch >= 0x30 and ch <= 0x39 then
        if key_event:shift() then
            -- Shift+数字交给后面的符号处理逻辑
            last_was_number = false
            return kNoop
        end
        -- 空码时数字直接上屏（原 direct_ascii 逻辑）
        if input == "" and not context:get_option("ascii_mode") and digits_enabled(env) then
            engine:commit_text(tostring(ch - 0x30))
            last_was_number = true  -- 仅在数字真正上屏后才标记
            return kAccepted
        end
        -- 有候选时数字用于选重，不标记 last_was_number
        return kNoop
    end

    -- 检查是否是目标符号
    local punct_info = punct_by_keycode[ch]
    if not punct_info then
        last_was_number = false
        -- 空码时英文句点等 configured_symbols 直接上屏（原 direct_ascii 逻辑）
        if input == "" and not context:get_option("ascii_mode") then
            local key = key_event:repr()
            local symbol = (#tostring(key) == 1 and key) or KEY_TEXT[key]
            if symbol and configured_symbols(env):find(symbol, 1, true) then
                engine:commit_text(symbol)
                return kAccepted
            end
        end
        return kNoop
    end

    -- 计算器模式：input 以 = 开头时，所有符号均放行给 speller，
    -- 让 . , + - * / ( ) 等正常进入编码串参与表达式求值。
    -- 仅对句号和逗号做此豁免（其他运算符本身已受开关控制或为半角）。
    if input ~= "" and input:sub(1, 1) == "=" then
        last_was_number = false
        return kNoop
    end

    -- 以下是 punct_direct_processor 的符号处理逻辑
    local half_char = punct_info[2]
    local full_char = punct_info[3]
    local switch_name = punct_info[4]  -- 开关名称，nil 表示不受控制
    local pass_when_has_menu = punct_info[5]  -- true=有候选时放行给 key_binder

    -- 有候选时放行（如 & 需要交给 key_binder toggle emoji_cn）
    if pass_when_has_menu and input ~= "" then
        last_was_number = false
        return kNoop
    end

    -- 检查开关状态：true=编辑模式（不处理），false=直接上屏
    if switch_name and context.get_option then
        local enabled = context:get_option(switch_name)
        if enabled then
            -- 编辑模式：放行给后续 processor
            last_was_number = false
            return kNoop
        end
    end

    -- 有输入时：先上屏首选
    if input ~= "" then
        local candidate = context:get_selected_candidate()
        if candidate then
            context:commit()
        else
            context:clear()
        end
    end

    -- 英文模式：半角；中文模式：全角
    local ascii_mode = context.get_option and context:get_option("ascii_mode")
    if punct_info[1] == "period" and last_was_number then
        engine:commit_text(".")
    elseif ascii_mode then
        engine:commit_text(half_char)
    else
        engine:commit_text(full_char)
    end

    last_was_number = false
    return kAccepted
end

return { func = processor }
