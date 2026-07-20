-- punct_direct_processor.lua
-- 符号直接上屏处理器
--   . 句号：固定直接上屏（不受开关控制）
--   = 等号：独立开关控制（equal_direct_enabled）
--   ; 分号：独立开关控制（quick_symbol_enabled，复用快符开关）
--   其他符号：受符号开关控制（punct_direct_enabled）

local kAccepted = 1
local kNoop = 2

-- 记录最近是否输入过数字
local last_was_number = false

-- 符号映射表
-- keycode = { 符号名, 半角, 全角, 开关名 }
-- 开关名为 nil 表示不受开关控制，固定直接上屏
local punct_by_keycode = {
    [0x2E] = { "period",    ".", "。", nil },                    -- . 句号（固定直接上屏）
    [0x3D] = { "equal",     "=", "=", "equal_direct_enabled" },  -- = 等号（独立开关）
    [0x3B] = { "semicolon", ";", "；", "quick_symbol_enabled" },-- ; 分号（独立开关，复用快符开关）
    [0x2F] = { "slash",     "/", "/", "punct_direct_enabled" },  -- / 斜杠
    [0x5C] = { "backslash", "\\", "、", "punct_direct_enabled" },-- \ 反斜杠
    [0x2A] = { "asterisk",  "*", "*", "punct_direct_enabled" },  -- * 星号
    [0x26] = { "ampersand", "&", "&", "punct_direct_enabled" },  -- & (Shift+7)
    [0x24] = { "dollar",    "$", "￥", "punct_direct_enabled" }, -- $ (Shift+4)
    [0x27] = { "apostrophe","'", "'", "punct_direct_enabled" },  -- ' 单引号
}

local function processor(key_event, env)
    if key_event:release() or key_event:ctrl() or key_event:alt() or key_event:super() then
        return kNoop
    end

    local ch = key_event.keycode
    
    -- 记录数字键输入（0-9）
    if ch >= 0x30 and ch <= 0x39 then
        if key_event:shift() then
            -- Shift+数字会被下面的符号处理
        else
            last_was_number = true
        end
        return kNoop
    end
    
    -- 检查是否是目标符号
    local punct_info = punct_by_keycode[ch]
    if not punct_info then
        last_was_number = false
        return kNoop
    end
    
    local context = env.engine.context
    local input = context.input or ""
    local half_char = punct_info[2]
    local full_char = punct_info[3]
    local switch_name = punct_info[4]  -- 开关名称，nil 表示不受控制
    
    -- 检查开关状态
    if switch_name then
        local enabled = context:get_option(switch_name)
        -- enabled = true 表示"开"（编辑模式），false 表示"关"（直接上屏）
        if enabled then
            -- 编辑模式：不处理
            last_was_number = false
            return kNoop
        end
    end

    local engine = env.engine

    -- 英文模式：输出半角
    local ascii_mode = context:get_option("ascii_mode")
    if ascii_mode then
        engine:commit_text(half_char)
        last_was_number = false
        return kAccepted
    end

    -- 判断是否是"数字输入状态"
    local is_number_input = input:match("^[0-9]+$") ~= nil or last_was_number

    -- 有输入时：先上屏首选
    if input ~= "" then
        local candidate = context:get_selected_candidate()
        if candidate then
            context:commit()
        else
            context:clear()
        end
    end

    -- 根据输入类型决定输出
    if is_number_input then
        engine:commit_text(half_char)
    else
        engine:commit_text(full_char)
    end

    last_was_number = false
    return kAccepted
end

return { func = processor }
