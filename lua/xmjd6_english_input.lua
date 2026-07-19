-- i键英文快捷输入
-- 按下i后接续输入英文单词（如itea），空格仅上屏英文部分tea（去掉前导i），回车完整上屏itea
-- 兼容原有i键历史记录功能：单独按i后直接回车，正常上屏单个字母i
-- 作者：皮皮

local string_sub = string.sub
local string_match = string.match
local string_byte = string.byte
local key_event_util = require("xmjd6_key_event")

local M = {}
local kAccepted = 1

-- i英文输入模式匹配：i后跟至少2个纯小写字母
-- 至少2个字母以兼容i+单字母的形码输入（如ia=冂、io=金）
local ENGLISH_PATTERN = "^i[a-z][a-z]+$"

-- 检测input是否匹配i+英文模式
function M.is_english_input(input)
    if not input or #input < 2 then return false end
    return string_match(input, ENGLISH_PATTERN) ~= nil
end

-- 判断key是否为小写字母按键（基于keycode）
local function is_alpha_key(kc, clean_key)
    if kc >= 97 and kc <= 122 then return true end
    if kc >= 65 and kc <= 90 then return true end
    if type(clean_key) == "string" and #clean_key == 1 then
        local b = string_byte(clean_key, 1)
        if (b >= 97 and b <= 122) or (b >= 65 and b <= 90) then return true end
    end
    return false
end

-- 获取小写字母字符
local function lower_alpha_char(kc, clean_key)
    if kc >= 97 and kc <= 122 then return string.char(kc) end
    if kc >= 65 and kc <= 90 then return string.char(kc + 32) end
    if type(clean_key) == "string" and #clean_key == 1 then
        local b = string_byte(clean_key, 1)
        if b >= 97 and b <= 122 then return clean_key end
        if b >= 65 and b <= 90 then return string.char(b + 32) end
    end
    return nil
end

-- 处理空格键：英文模式下仅上屏英文部分（去掉前导i）
-- 返回 kAccepted 表示已处理，nil 表示交由后续逻辑
function M.handle_space(env, ctx, key_event, clean_key, repr, kc, no_modifier)
    if not (no_modifier and key_event_util.is_space(kc, clean_key, repr)) then return nil end
    if not M.is_english_input(ctx.input) then return nil end
    if key_event:release() then return kAccepted end
    local english_part = string_sub(ctx.input, 2)
    ctx:clear()
    env.engine:commit_text(english_part)
    return kAccepted
end

-- 拦截顶功：当ctx.input以i开头且即将输入英文字母时，直接push_input并阻止顶功
-- 返回 kAccepted 表示已处理（阻止顶功），nil 表示交由后续逻辑
function M.handle_alpha_press(env, ctx, key, clean_key, kc, no_modifier)
    if not (no_modifier and not key_event_util.is_reverse_input(env, ctx.input)) then return nil end
    local input = ctx.input or ""
    -- ctx.input为"i"且按下英文字母：进入英文模式
    if input == "i" and is_alpha_key(kc, clean_key) then
        local char = lower_alpha_char(kc, clean_key)
        if char and env._alpha and env._alpha[char] then
            ctx:push_input(char)
            return kAccepted
        end
    end
    -- 已在英文模式中，继续输入英文字母
    if M.is_english_input(input) and is_alpha_key(kc, clean_key) then
        local char = lower_alpha_char(kc, clean_key)
        if char and env._alpha and env._alpha[char] then
            ctx:push_input(char)
            return kAccepted
        end
    end
    return nil
end

-- 处理退格：英文模式下退格到只剩"i"时，退出英文模式（让原有逻辑接管）
function M.handle_backspace(env, ctx, key_event, clean_key, repr, kc, no_modifier)
    if not (no_modifier and key_event_util.is_topup_cancel(clean_key, repr, kc)) then return nil end
    if not M.is_english_input(ctx.input) then return nil end
    if key_event:release() then return kAccepted end
    ctx:pop_input(1)
    return kAccepted
end

-- 清除英文模式状态
function M.clear(env)
    -- 目前无状态需清除，预留接口
end

return M
