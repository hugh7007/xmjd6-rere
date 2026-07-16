-- 天行键按键事件解析与键位语义
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-10

local string_find = string.find
local string_lower = string.lower
local string_match = string.match
local type = type

local M = {}

local CHAR_CACHE = {}
for i = 0, 255 do CHAR_CACHE[i] = string.char(i) end
M.char_cache = CHAR_CACHE

local KEYCODE_NAME = {
    [59] = "semicolon", [58] = "semicolon",
    [39] = "apostrophe", [34] = "apostrophe",
    [44] = "comma", [60] = "comma",
    [46] = "period", [62] = "period",
    [47] = "slash", [63] = "slash",
    [45] = "minus", [95] = "minus",
    [61] = "equal", [43] = "equal",
    [91] = "bracketleft", [123] = "bracketleft",
    [93] = "bracketright", [125] = "bracketright",
    [92] = "backslash", [124] = "backslash",
    [96] = "grave",
}

local KEY_ALIAS = {
    ["/"] = "slash", ["?"] = "slash", ["slash"] = "slash", ["question"] = "slash",
    ["\\"] = "backslash", ["|"] = "backslash", ["backslash"] = "backslash", ["bar"] = "backslash",
    ["-"] = "minus", ["_"] = "minus", ["minus"] = "minus", ["underscore"] = "minus",
    [";"] = "semicolon", [":"] = "semicolon", ["semicolon"] = "semicolon", ["colon"] = "semicolon",
    ["'"] = "apostrophe", ["\""] = "apostrophe", ["apostrophe"] = "apostrophe", ["quotedbl"] = "apostrophe",
    ["="] = "equal", ["+"] = "equal", ["equal"] = "equal", ["plus"] = "equal",
    ["["] = "bracketleft", ["{"] = "bracketleft", ["bracketleft"] = "bracketleft",
    ["]"] = "bracketright", ["}"] = "bracketright", ["bracketright"] = "bracketright",
    ["braceleft"] = "bracketleft", ["braceright"] = "bracketright",
    [","] = "comma", ["<"] = "comma", ["comma"] = "comma", ["less"] = "comma",
    ["."] = "period", [">"] = "period", ["period"] = "period", ["greater"] = "period",
    ["`"] = "grave", ["~"] = "grave", ["grave"] = "grave",
    ["asciitilde"] = "grave", ["dead_tilde"] = "grave", ["dead_grave"] = "grave",
}

local PLATFORM_KEYCODE_NAME = {
    [0xBA] = "semicolon", [0xBB] = "equal", [0xBC] = "comma", [0xBD] = "minus",
    [0xBE] = "period", [0xBF] = "slash", [0xC0] = "grave", [0xDB] = "bracketleft",
    [0xDC] = "backslash", [0xDD] = "bracketright", [0xDE] = "apostrophe",
    [59] = "semicolon", [58] = "semicolon", [39] = "apostrophe", [34] = "apostrophe",
    [44] = "comma", [60] = "comma", [46] = "period", [62] = "period",
    [47] = "slash", [63] = "slash", [45] = "minus", [95] = "minus",
    [61] = "equal", [43] = "equal", [91] = "bracketleft", [123] = "bracketleft",
    [93] = "bracketright", [125] = "bracketright", [92] = "backslash",
    [124] = "backslash", [96] = "grave",
}

local SHIFTED_NAME = {
    ["<"] = true, [">"] = true, ["?"] = true, ["|"] = true,
    ["{"] = true, ["}"] = true, [":"] = true, ["\""] = true,
    ["less"] = true, ["greater"] = true, ["question"] = true, ["bar"] = true,
    ["braceleft"] = true, ["braceright"] = true, ["colon"] = true, ["quotedbl"] = true,
    ["_"] = true, ["underscore"] = true, ["+"] = true, ["plus"] = true,
}

local function normalize_key(key)
    if type(key) ~= "string" then return key end
    local lower = string_lower(key)
    if lower == "kp_equal" or lower == "numpad_equal" then return "equal" end
    return KEY_ALIAS[lower] or KEY_ALIAS[key] or lower
end

function M.resolve(key_event, env)
    local keycode = key_event.keycode
    local repr = key_event:repr()
    local clean_key = repr
    if type(repr) == "string" then
        clean_key = string_match(repr, "^[Ss]hift%+(.*)") or repr
    end

    local key_name = normalize_key(clean_key)
    local keycode_name = PLATFORM_KEYCODE_NAME[keycode] or KEYCODE_NAME[keycode]
    if keycode_name then key_name = keycode_name end

    local shift = key_event:shift()
    if not key_event:release() then
        if keycode_name then
            env._ks = env._ks or {}
            env._ks[keycode] = shift
        end
    elseif env._ks and env._ks[keycode] ~= nil then
        shift = env._ks[keycode]
        env._ks[keycode] = nil
    end

    if type(repr) == "string" and SHIFTED_NAME[repr] then shift = true end
    if type(repr) == "string" and (string_find(repr, "tilde") or string_find(repr, "grave")) then
        key_name = "grave"
    end
    if key_name == "grave" and (repr == "~" or repr == "asciitilde" or repr == "dead_tilde"
        or (type(repr) == "string" and string_find(repr, "tilde"))) then
        shift = true
    end

    if type(clean_key) ~= "string" then
        clean_key = (keycode >= 0 and keycode <= 255) and CHAR_CACHE[keycode] or ""
    end
    return key_name, shift, clean_key, repr
end

function M.digit_char(clean_key, keycode, repr)
    local char = keycode and keycode >= 48 and keycode <= 57 and CHAR_CACHE[keycode] or nil
    if char then return char end
    if type(clean_key) == "string" and string_match(clean_key, "^%d$") then return clean_key end
    if type(repr) == "string" and string_match(repr, "^%d$") then return repr end
    return nil
end

function M.is_space(keycode, clean_key, repr)
    local repr_lower = type(repr) == "string" and string_lower(repr) or ""
    return keycode == 32 or clean_key == " " or repr_lower == "space"
end

function M.is_topup_cancel(clean_key, repr, keycode)
    if keycode == 0xff08 or keycode == 0xffff or keycode == 0xff1b then return true end
    local key = type(clean_key) == "string" and string_lower(clean_key) or ""
    local raw = type(repr) == "string" and string_lower(repr) or ""
    return key == "backspace" or key == "delete" or key == "escape"
        or raw == "backspace" or raw == "delete" or raw == "escape"
end

function M.is_append_delete(clean_key, repr, keycode)
    if keycode == 0xff08 or keycode == 0xffff then return true end
    local key = type(clean_key) == "string" and string_lower(clean_key) or ""
    local raw = type(repr) == "string" and string_lower(repr) or ""
    return key == "backspace" or key == "delete" or raw == "backspace" or raw == "delete"
end

function M.is_enter(clean_key, repr, keycode)
    if keycode == 13 or keycode == 0xff0d or keycode == 0xff8d then return true end
    local key = type(clean_key) == "string" and string_lower(clean_key) or ""
    local raw = type(repr) == "string" and string_lower(repr) or ""
    return key == "return" or key == "enter" or key == "kp_enter"
        or raw == "return" or raw == "enter" or raw == "kp_enter"
end

function M.is_shift(clean_key, repr, keycode)
    if keycode == 0xffe1 or keycode == 0xffe2 then return true end
    local key = type(clean_key) == "string" and string_lower(clean_key) or ""
    local raw = type(repr) == "string" and string_lower(repr) or ""
    return key == "shift_l" or key == "shift_r" or key == "shift"
        or raw == "shift_l" or raw == "shift_r" or raw == "shift"
end

function M.is_caps(clean_key, repr, keycode)
    if keycode == 0xffe5 then return true end
    local key = type(clean_key) == "string" and string_lower(clean_key) or ""
    local raw = type(repr) == "string" and string_lower(repr) or ""
    return key == "caps_lock" or key == "capslock" or key == "caps"
        or raw == "caps_lock" or raw == "capslock" or raw == "caps"
end

function M.uppercase_char(clean_key, keycode)
    if keycode >= 65 and keycode <= 90 then return CHAR_CACHE[keycode] end
    if type(clean_key) ~= "string" or #clean_key ~= 1 then return nil end
    local byte = string.byte(clean_key, 1)
    if byte >= 65 and byte <= 90 then return clean_key end
    return nil
end

function M.alpha_upper_char(clean_key, keycode)
    if keycode >= 97 and keycode <= 122 then return CHAR_CACHE[keycode - 32] end
    if keycode >= 65 and keycode <= 90 then return CHAR_CACHE[keycode] end
    if type(clean_key) == "string" and string_match(clean_key, "^[A-Za-z]$") then
        return string.upper(clean_key)
    end
    return nil
end

function M.bare_upper_alpha_char(clean_key, keycode, repr)
    if keycode >= 65 and keycode <= 90 then return CHAR_CACHE[keycode] end
    if type(clean_key) == "string" and #clean_key == 1 then
        local byte = string.byte(clean_key, 1)
        if byte >= 65 and byte <= 90 then return clean_key end
    end
    if type(repr) == "string" and #repr == 1 then
        local byte = string.byte(repr, 1)
        if byte >= 65 and byte <= 90 then return repr end
    end
    return nil
end

function M.is_caps_on(key_event)
    local ok, value = pcall(function() return key_event:caps() end)
    return ok and value == true
end

function M.repr_has_lock(repr)
    return type(repr) == "string" and string_find(repr, "Lock+", 1, true) ~= nil
end

function M.effective_caps_on(env, key_event)
    local repr = key_event and key_event:repr() or nil
    if M.repr_has_lock(repr) or M.is_caps_on(key_event) then return true end
    if env and env._caps_lock_on ~= nil then return env._caps_lock_on end
    return false
end

function M.is_reverse_input(env, input)
    if not input or input == "" or not env._rx_prefix then return false end
    return env._rx_prefix[string.sub(input, 1, 1)] == true
end

function M.is_alpha(env, key, clean_key, keycode)
    if (keycode >= 65 and keycode <= 90) or (keycode >= 97 and keycode <= 122) then return true end
    if type(key) == "string" and env._alpha[string_lower(key)] then return true end
    if type(clean_key) == "string" and env._alpha[string_lower(clean_key)] then return true end
    return false
end

function M.passthrough_alpha(env, ctx, shift, key, clean_key, keycode)
    if not M.is_alpha(env, key, clean_key, keycode) then return false end
    return shift or M.is_reverse_input(env, ctx.input)
end

function M.shift_inline_alpha(env, ctx, shift, key, clean_key, keycode)
    if not env._shift_inline_ascii then return false end
    if shift or not ctx:is_composing() or (ctx.input or "") == "" then
        env._shift_inline_ascii = nil
        return false
    end
    if not M.is_alpha(env, key, clean_key, keycode) then
        env._shift_inline_ascii = nil
        return false
    end
    return true
end

return M

