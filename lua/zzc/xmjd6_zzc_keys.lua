-- 天行键 自造词按键解析模块
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-10

local M = {}

M.length_keys = {
    ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6,
    ["三"] = 3, ["四"] = 4, ["五"] = 5, ["六"] = 6,
    ["KP_3"] = 3, ["KP_4"] = 4, ["KP_5"] = 5, ["KP_6"] = 6,
    ["kp_3"] = 3, ["kp_4"] = 4, ["kp_5"] = 5, ["kp_6"] = 6,
}

M.index_keys = {
    ["1"] = 1, ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5,
    ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9,
    ["KP_1"] = 1, ["KP_2"] = 2, ["KP_3"] = 3, ["KP_4"] = 4, ["KP_5"] = 5,
    ["KP_6"] = 6, ["KP_7"] = 7, ["KP_8"] = 8, ["KP_9"] = 9,
    ["kp_1"] = 1, ["kp_2"] = 2, ["kp_3"] = 3, ["kp_4"] = 4, ["kp_5"] = 5,
    ["kp_6"] = 6, ["kp_7"] = 7, ["kp_8"] = 8, ["kp_9"] = 9,
}

local collect_select_keys = {
    [";"] = 2, semicolon = 2, Semicolon = 2,
    ["'"] = 3, apostrophe = 3, Apostrophe = 3,
    Tab = 2, tab = 2,
}

local trigger_keys = {
    ["\\"] = true,
    backslash = true,
    Backslash = true,
    bar = true,
    ["|"] = true,
}

local symbol_keys = {
    ["\\"] = true, ["|"] = true,
    backslash = true, bar = true, Backslash = true,
    Escape = true, escape = true,
    Backspace = true, backspace = true,
    less = true, Less = true, ["<"] = true,
    minus = true, Minus = true, hyphen = true, Hyphen = true, ["-"] = true,
    space = true, Space = true, [" "] = true,
}

local key_code_char_map = {
    semicolon = ";",
    apostrophe = "'",
}

local function strip_shift(key)
    if type(key) ~= "string" then return key end
    return key:match("^[Ss]hift%+(.*)") or key
end

function M.normalize_trigger_key(key)
    if type(key) ~= "string" then return key end
    local clean = key
    local changed = true
    while changed do
        changed = false
        local stripped = clean:match("^[Ss]hift%+(.*)")
            or clean:match("^[Rr]elease%+(.*)")
        if stripped and stripped ~= clean then
            clean = stripped
            changed = true
        end
    end
    local payload = clean:match("^[Cc]haracter%((.*)%)$")
    if payload == "\\" or payload == "\\\\" or payload == "|" or payload == "backslash" then
        return "\\"
    end
    return clean
end

function M.event_char(key_event)
    local code = key_event and key_event.keycode
    if code and code >= 0x20 and code < 0x7f then return string.char(code) end
    return nil
end

function M.resolve_collect_modifier_select_key(key_event, key)
    if not key_event then return nil end
    local ctrl = key_event:ctrl()
    local alt = key_event:alt()
    local repr = tostring(key or "")
    local clean = repr:match("^[Cc]ontrol%+(.*)") or repr:match("^[Aa]lt%+(.*)") or repr
    local lower = clean:lower()
    local keycode = key_event.keycode
    local is_ctrl_key = lower == "control_l" or lower == "control_r" or lower == "control"
        or keycode == 17 or keycode == 0xffe3 or keycode == 0xffe4
    local is_alt_key = lower == "alt_l" or lower == "alt_r" or lower == "alt"
        or keycode == 18 or keycode == 0xffe9 or keycode == 0xffea
    if (ctrl or is_ctrl_key) and not alt and is_ctrl_key then return 2 end
    if (alt or is_alt_key) and not ctrl and is_alt_key then return 3 end
    return nil
end

function M.is_trigger(key, ch)
    if trigger_keys[ch or ""] or trigger_keys[key or ""] then return true end
    if type(key) ~= "string" then return false end
    local clean = M.normalize_trigger_key(key)
    return trigger_keys[clean] or trigger_keys[clean:lower()]
end

function M.is_code_char(ch)
    return type(ch) == "string" and ch:match("^[A-Za-z;']$") ~= nil
end

function M.resolve_code_char(key, ch)
    if M.is_code_char(ch) then return ch end
    if type(key) ~= "string" then return nil end
    local clean = strip_shift(key)
    if M.is_code_char(clean) then return clean end
    local mapped = key_code_char_map[clean:lower()]
    if mapped and M.is_code_char(mapped) then return mapped end
    return nil
end

function M.strip_zzc_prefix(input)
    input = input or ""
    if input:sub(1, 1) == "\\" then return input:sub(2) end
    return input
end

function M.code_backslash_target(input)
    input = tostring(input or "")
    if #input > 1 and input:sub(-1) == "\\" then return input:sub(1, -2) end
    return nil
end

function M.is_space(key)
    return type(key) == "string" and strip_shift(key):lower() == "space"
end

function M.is_less_key(key, ch)
    local fullwidth_less = string.char(0xEF, 0xBC, 0x9C)
    local left_angle = string.char(0xE3, 0x80, 0x8A)
    if ch == "<" or ch == "," or ch == fullwidth_less or ch == left_angle
        or key == "less" or key == "Less" or key == "comma" or key == fullwidth_less or key == left_angle then return true end
    if type(key) ~= "string" then return false end
    local clean = strip_shift(key)
    return clean == "<" or clean == fullwidth_less or clean == left_angle
        or clean == "comma" or clean:lower() == "less" or key:match("^[Ss]hift%+comma$")
end

function M.is_minus_key(key, ch)
    local fullwidth_minus = string.char(0xEF, 0xBC, 0x8D)
    local minus_sign = string.char(0xE2, 0x88, 0x92)
    if ch == "-" or ch == fullwidth_minus or ch == minus_sign then return true end
    if type(key) ~= "string" then return false end
    local clean = strip_shift(key)
    local lower = clean:lower()
    return lower == "minus" or lower == "hyphen" or clean == "-" or clean == fullwidth_minus or clean == minus_sign
end

function M.is_unshifted_equal_key(key, ch, shifted)
    if shifted then return false end
    if ch == "=" then return true end
    if type(key) ~= "string" then return false end
    local clean = strip_shift(key)
    return clean:lower() == "equal" or clean == "="
end

function M.is_plus_key(key, ch, shifted, keycode)
    local fullwidth_plus = string.char(0xEF, 0xBC, 0x8B)
    if ch == "+" or ch == fullwidth_plus then return true end
    if type(key) ~= "string" then return false end
    local clean = strip_shift(key)
    local lower = clean:lower()
    if lower == "equal" or clean == "=" then return true end
    if key:match("^[Ss]hift%+") and (lower == "equal" or clean == "=") then return true end
    if shifted and (lower == "equal" or clean == "=" or keycode == 61 or keycode == 0xBB or keycode == 43) then return true end
    return lower == "plus" or lower == "kp_add" or lower == "kp_plus"
        or lower == "numpad_add" or lower == "numpad_plus" or lower == "add"
        or keycode == 61 or keycode == 0xBB or keycode == 43
        or clean == "+" or clean == fullwidth_plus
end

function M.is_bang_key(key, ch, shifted, keycode)
    local fullwidth_bang = string.char(0xEF, 0xBC, 0x81)
    if ch == fullwidth_bang or key == fullwidth_bang or ch == "!" then return true end
    if shifted and (keycode == 49 or keycode == 0x31) then return true end
    if type(key) ~= "string" then return false end
    local shifted_key = key:match("^[Ss]hift%+") ~= nil
    local clean = strip_shift(key)
    local lower = clean:lower()
    return clean == "!" or clean == "！" or lower == "exclam" or (shifted_key and (clean == "1" or lower == "exclam"))
end

function M.is_backspace(key)
    return type(key) == "string" and key:lower() == "backspace"
end

function M.is_enter_key(key)
    if type(key) ~= "string" then return false end
    local lower = key:lower()
    return lower == "return" or lower == "enter"
end

function M.is_null_key(key)
    return key == "0x0000"
end

function M.is_ascii_mode(ctx)
    return ctx and ctx.get_option and ctx:get_option("ascii_mode")
end

function M.is_reserved_key(key, ch)
    if symbol_keys[key or ""] or symbol_keys[ch or ""] then return true end
    if type(key) ~= "string" then return false end
    local clean = strip_shift(key)
    return symbol_keys[clean] or symbol_keys[clean:lower()]
end

function M.resolve_length_key(key, ch)
    return M.length_keys[ch or ""] or M.length_keys[key or ""]
end

function M.resolve_index_key(key, ch)
    return M.index_keys[ch or ""] or M.index_keys[key or ""]
end

function M.resolve_collect_select_key(key, ch)
    return M.resolve_index_key(key, ch) or collect_select_keys[ch or ""] or collect_select_keys[key or ""]
end

return M
