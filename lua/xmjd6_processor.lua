-- 天行键 统一按键处理器
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-02

local string_sub = string.sub
local string_byte = string.byte
local string_match = string.match
local string_find = string.find
local string_lower = string.lower
local type = type
local config_util = require("common.xmjd6_config")
local platform = require("common.xmjd6_platform")
local state = require("common.xmjd6_state")
local registry = require("common.xmjd6_cache_registry")
local zzc_processor = require("zzc.xmjd6_zzc_processor")

local kAccepted = 1
local kNoop = 2

local CHAR_CACHE = {}
for i = 0, 255 do CHAR_CACHE[i] = string.char(i) end
local symbol_code_state

local function _digit_char(clean_key, kc, repr)
    local ch = kc and kc >= 48 and kc <= 57 and CHAR_CACHE[kc] or nil
    if ch then return ch end
    if type(clean_key) == "string" and string_match(clean_key, "^%d$") then return clean_key end
    if type(repr) == "string" and string_match(repr, "^%d$") then return repr end
    return nil
end

local function _s2set(str)
    return config_util.s2set(str)
end

local function _trim_trailing_sep(path)
    return (path or ""):gsub("[/\\]+$", "")
end

local function _dirname(path)
    return (path or ""):match("^(.*)[/\\][^/\\]*$") or ""
end

local function _join_path(base, name)
    if not base or base == "" then return name end
    return base .. "/" .. name
end


local function _module_project_dir()
    local info = debug and debug.getinfo and debug.getinfo(1, "S") or nil
    local source = info and info.source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    source = source:gsub("\\", "/")
    local lua_dir = _dirname(source)
    if lua_dir:match("/lua$") or lua_dir == "lua" then
        return _dirname(lua_dir)
    end
    return lua_dir
end

local function _push_unique_path(list, seen, path)
    path = _trim_trailing_sep(path)
    if path ~= "" and not seen[path] then
        seen[path] = true
        list[#list + 1] = path
    end
end

local function _core_dict_candidates(schema_id)
    local file_name = ((schema_id and schema_id ~= "") and schema_id or "xmjd6") .. ".core.dict.yaml"
    local candidates, seen = {}, {}
    _push_unique_path(candidates, seen, file_name)
    _push_unique_path(candidates, seen, _join_path(_module_project_dir(), file_name))
    local api = rime_api
    if api and api.get_user_data_dir then
        local ok, user_dir = pcall(api.get_user_data_dir)
        if ok and type(user_dir) == "string" and user_dir ~= "" then
            _push_unique_path(candidates, seen, _join_path(user_dir, file_name))
        end
    end
    return candidates
end

local function _find_existing_path(candidates)
    for _, path in ipairs(candidates or {}) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

local function _load_symbol_code_state(schema_id)
    local path = _find_existing_path(_core_dict_candidates(schema_id))
    local state = { codes = {}, prefixes = {}, max_len = 0 }
    if not path then return state end
    local f = io.open(path, "r")
    if not f then return state end
    local in_region = false
    for line in f:lines() do
        if line:match("^%s*#region%s+<快符>%s*$") then
            in_region = true
        elseif line:match("^%s*#endregion%s+<快符>%s*$") then
            break
        elseif in_region and not line:match("^%s*#") then
            local code = line:match("^[^\t]+\t(;%S+)")
            if code then code = string_sub(code, 2) end
            if code and code ~= "" then
            state.codes[code] = true
            if #code > state.max_len then state.max_len = #code end
            for i = 1, #code - 1 do
                state.prefixes[string_sub(code, 1, i)] = true
            end
            end
        end
    end
    f:close()
    return state
end

local function _symbol_code_state(schema_id)
    if not symbol_code_state then
        symbol_code_state = _load_symbol_code_state(schema_id)
    end
    return symbol_code_state
end

local function _config_bool(config, path, default)
    local value = config and config:get_bool(path)
    if value ~= nil then return value end
    local text = config and config:get_string(path)
    if text == "false" or text == "0" or text == "off" or text == "no" then return false end
    if text == "true" or text == "1" or text == "on" or text == "yes" then return true end
    return default
end

local function _collect_reverse_prefixes(config, schema_id, include_aux)
    return config_util.collect_reverse_prefixes(config, schema_id, include_aux)
end

local _SymCN = {
    ["slash"]      = { plain = "/", shift = "？" },
    ["backslash"]  = { plain = "\\", shift = "·" },
    ["minus"]      = { plain = "-", shift = "——" },
    ["equal"]      = { plain = "＝", shift = "+" },
    ["semicolon"]  = { plain = "；", shift = "：" },
    ["apostrophe"] = { plain = "‘", shift = "“" },
    ["bracketleft"]  = { plain = "【", shift = "{" },
    ["bracketright"] = { plain = "】", shift = "}" },
    ["comma"]      = { plain = "，", shift = "《" },
    ["period"]     = { plain = "。", shift = "》" },
    ["grave"]      = { plain = "·", shift = "～" },
}
local _SmOff = { ["semicolon"] = { plain = ";", shift = "：" }, ["apostrophe"] = { plain = "'", shift = "“" } }
local _JsOff = { ["equal"] = { plain = "=", shift = "+" } }

local _KC_MAP = {
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
    [96] = "grave"
}

local _KA = {
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
    ["asciitilde"] = "grave", ["dead_tilde"] = "grave", ["dead_grave"] = "grave"
}

local _KC = {
    [0xBA] = "semicolon", [0xBB] = "equal", [0xBC] = "comma", [0xBD] = "minus",
    [0xBE] = "period", [0xBF] = "slash", [0xC0] = "grave", [0xDB] = "bracketleft",
    [0xDC] = "backslash", [0xDD] = "bracketright", [0xDE] = "apostrophe",
    [59] = "semicolon", [58] = "semicolon", [39] = "apostrophe", [34] = "apostrophe",
    [44] = "comma", [60] = "comma", [46] = "period", [62] = "period",
    [47] = "slash", [63] = "slash", [45] = "minus", [95] = "minus",
    [61] = "equal", [43] = "equal", [91] = "bracketleft", [123] = "bracketleft",
    [93] = "bracketright", [125] = "bracketright", [92] = "backslash",
    [124] = "backslash", [96] = "grave"
}

local _SN = {
    ["<"]=1, [">"]=1, ["?"]=1, ["|"]=1, ["{"]=1, ["}"]=1, [":"]=1, ["\""]=1,
    ["less"]=1, ["greater"]=1, ["question"]=1, ["bar"]=1,
    ["braceleft"]=1, ["braceright"]=1, ["colon"]=1, ["quotedbl"]=1,
    ["_"]=1, ["underscore"]=1, ["+"]=1, ["plus"]=1
}

local function _nk(key)
    if type(key) ~= "string" then return key end
    local l = key:lower()
    if l == "kp_equal" or l == "numpad_equal" then return "equal" end
    return _KA[l] or _KA[key] or l
end

local _CalcKey = {
    ["space"] = " ", ["minus"] = "-", ["equal"] = "=", ["slash"] = "/",
    ["backslash"] = "\\",
    ["comma"] = ",", ["period"] = ".", ["bracketleft"] = "[",
    ["bracketright"] = "]", ["grave"] = "`",
}
local _CalcShiftKey = {
    ["minus"] = "_", ["equal"] = "+", ["slash"] = "?",
    ["backslash"] = "|", ["semicolon"] = ":", ["apostrophe"] = "\"",
    ["comma"] = "<", ["period"] = ">", ["bracketleft"] = "{",
    ["bracketright"] = "}", ["grave"] = "~",
}
local _CalcShiftDigitKey = {
    [48] = ")", [49] = "!", [51] = "#", [52] = "$", [53] = "%",
    [54] = "^", [55] = "&", [56] = "*", [57] = "(",
}
local _CalcSymbolSet = _s2set("+-*/%^#=~<>(){}[].,:$\\|&\"_?! ")

local function _tdc(map, kn, sf, engine, ctx)
    local c = map[kn]
    if not c then return false end
    local sym = sf and c.shift or c.plain
    if not sym then return false end
    if ctx:is_composing() then ctx:commit() end
    engine:commit_text(sym)
    return true
end

local function _guard_shift_symbol_release(env, sf)
    if sf then env._shift_symbol_release_guard = true end
end

local function _topup_ready(env, ctx)
    if env._tc then
        env._tc = env._tc + 1
        if env._tc > 200 then env._tc = 81 end
    elseif env._tc_pending then
        env._tc_pending = false
        local rv = ctx:get_property("_rvk")
        if not rv or rv == "" then env._tc = 0 end
    end

    if env._tc and env._tc >= 80 then
        if ctx:is_composing() then ctx:clear() end
        return false
    end
    return true
end

local _is_completion_candidate

local function _selected_candidate(ctx)
    return ctx and ctx:get_selected_candidate() or nil
end

local function _is_raw_input_candidate(ctx, cand)
    local input = ctx and (ctx.input or "") or ""
    if input == "" or not cand or cand.text ~= input then return false end
    local cand_type = cand.type
    if cand.get_genuine then
        local ok, genuine = pcall(function() return cand:get_genuine() end)
        if ok and genuine and genuine.type then cand_type = genuine.type end
    end
    return cand_type == "raw" or cand_type == "ascii" or string_match(input, "^[a-z;']+$") ~= nil
end

local function _selected_is_non_completion(ctx)
    local cand = _selected_candidate(ctx)
    return cand and not (_is_completion_candidate and _is_completion_candidate(cand))
        and not _is_raw_input_candidate(ctx, cand) or false
end

local function _commit_selected_non_completion(ctx)
    local cand = _selected_candidate(ctx)
    if not cand then return false end
    if _is_completion_candidate and _is_completion_candidate(cand) then return false end
    if _is_raw_input_candidate(ctx, cand) then return false end
    ctx:commit()
    return true
end

local function _commit_selected_candidate(ctx)
    local cand = _selected_candidate(ctx)
    if not cand then return false end
    ctx:commit()
    return true
end

local function _has_semicolon_prefix(input)
    return type(input) == "string" and #input > 0 and string_byte(input, 1) == 59
end

local function _is_memory_tool_input(input)
    return input == "=mem" or input == "=mem!"
end

local function _is_direct_symbols_input(input)
    return type(input) == "string" and #input > 1 and string_byte(input, 1) == 59
end

local function _space_guard_clear(env)
    env._space_guard_input = nil
    env._space_guard_wait = nil
    env._space_guard_refreshed_input = nil
end

local function _space_guard_note(env, ctx, before_input, key)
    if not env._space_guard_enabled then return end
    if type(key) ~= "string" or #key ~= 1 then return end
    if not (env._alpha and env._alpha[key]) then return end
    before_input = before_input or (ctx and (ctx.input or "")) or ""
    local expected = before_input .. key
    if #expected >= (env._tu_max or 6) then
        _space_guard_clear(env)
        return
    end
    env._space_guard_input = expected
    env._space_guard_wait = nil
end

local function _push_code_input(env, ctx, key)
    local before_input = ctx and (ctx.input or "") or ""
    ctx:push_input(key)
    _space_guard_note(env, ctx, before_input, key)
end

local function _topup_exec(env)
    local ctx = env.engine.context
    if not _topup_ready(env, ctx) then return false end

    if zzc_processor and zzc_processor.is_active and zzc_processor.is_active(ctx) then
        local next_input = env._xmjd6_zzc_follow_key
        env._xmjd6_zzc_follow_key = nil
        if zzc_processor.capture_current_candidate and zzc_processor.capture_current_candidate(ctx, next_input) then
            return true, next_input ~= nil
        end
    end

    if not _commit_selected_non_completion(ctx) then
        if env._tu_ac then ctx:clear() end
    end
    return true, false
end

local function _topup_queue_key(env, ctx, key, clean_key, kc)
    env._tu_pending_key = key
    env._tu_pending_clean = clean_key
    env._tu_pending_kc = kc
    env._tu_pending_input = ctx and (ctx.input or "") or ""
end

local function _topup_clear_pending_key(env)
    env._tu_pending_key = nil
    env._tu_pending_clean = nil
    env._tu_pending_kc = nil
    env._tu_pending_input = nil
end

local function _topup_clear_queued_keys(env)
    _topup_clear_pending_key(env)
end

local function _topup_flush_key(env, ctx)
    local key = env._tu_pending_key
    if not key then return false end
    local pending_input = env._tu_pending_input
    if pending_input and ctx and (ctx.input or "") ~= pending_input then
        if ctx:is_composing() or (ctx.input or "") ~= "" then
            _topup_clear_pending_key(env)
            return false
        end
    end
    _topup_clear_pending_key(env)
    _push_code_input(env, ctx, key)
    env._af_seed = key
    return true
end

local function _topup_handle_queued_release(env, ctx, clean_key, kc)
    if env._tu_pending_key and (clean_key == env._tu_pending_clean or kc == env._tu_pending_kc) then
        return _topup_flush_key(env, ctx)
    end
    return false
end

local function _topup_is_pending_key_event(env, key, kc)
    return env._tu_pending_key and key == env._tu_pending_key and kc == env._tu_pending_kc
end

local function _topup_flush_plain_alpha_press(env, ctx, key_event, key, sf, caps_on)
    if not env._tu_pending_key or key_event:release() or sf or caps_on then return false end
    if key_event:ctrl() or key_event:alt() or key_event:super() then return false end
    if type(key) ~= "string" or #key ~= 1 then return false end
    local b = string_byte(key, 1)
    if b < 97 or b > 122 or not (env._alpha and env._alpha[key]) then return false end
    if _topup_is_pending_key_event(env, key, key_event.keycode) then return false end
    if not _topup_flush_key(env, ctx) then return false end
    _push_code_input(env, ctx, key)
    return true
end

local function _plain_code_key(env, key, clean_key, kc)
    if not env._alpha then return nil end
    local code_key = nil
    if kc >= 65 and kc <= 90 then
        code_key = CHAR_CACHE[kc + 32]
    elseif kc >= 97 and kc <= 122 then
        code_key = CHAR_CACHE[kc]
    end
    if not code_key and type(key) == "string" and #key == 1 then
        local b = string_byte(key, 1)
        if b >= 65 and b <= 90 then
            code_key = CHAR_CACHE[b + 32]
        elseif b >= 97 and b <= 122 then
            code_key = key
        end
    end
    if not code_key and type(clean_key) == "string" and #clean_key == 1 then
        local b = string_byte(clean_key, 1)
        if b >= 65 and b <= 90 then
            code_key = CHAR_CACHE[b + 32]
        elseif b >= 97 and b <= 122 then
            code_key = clean_key
        end
    end
    return code_key and env._alpha[code_key] and code_key or nil
end

local function _cold_start_push_code_key(env, ctx, key_event, key, sf, caps_on)
    if not env._cold_code_guard or key_event:release() or sf or caps_on then return false end
    if key_event:ctrl() or key_event:alt() or key_event:super() then return false end
    if env._tu_pending_key then return false end
    if ctx:is_composing() or (ctx.input or "") ~= "" then
        env._cold_code_guard = nil
        return false
    end
    if not key then return false end
    env._cold_code_guard = nil
    _push_code_input(env, ctx, key)
    return true
end

local function _topup_push_key(env, ctx, key, clean_key, kc, input_len)
    if input_len and input_len >= 1 then
        _topup_queue_key(env, ctx, key, clean_key, kc)
        _space_guard_note(env, ctx, ctx and (ctx.input or "") or "", key)
    else
        _push_code_input(env, ctx, key)
        env._af_seed = key
    end
end

local function _resolve_key(key_event, env)
    local kc = key_event.keycode
    local raw_key = key_event:repr()
    local clean_key = raw_key
    if type(raw_key) == "string" then
        clean_key = string_match(raw_key, "^[Ss]hift%+(.*)") or raw_key
    end

    local kn = _nk(clean_key)
    local kcn = _KC[kc] or _KC_MAP[kc]
    if kcn then kn = kcn end

    local sf = key_event:shift()
    
    if not key_event:release() then
        if kcn then
            env._ks = env._ks or {}
            env._ks[kc] = sf
        end
    else
        if env._ks and env._ks[kc] ~= nil then
            sf = env._ks[kc]
            env._ks[kc] = nil
        end
    end

    if type(raw_key) == "string" and _SN[raw_key] then sf = true end
    if type(raw_key) == "string" then
        if string_find(raw_key, "tilde") or string_find(raw_key, "grave") then kn = "grave" end
    end
    if kn == "grave" and (raw_key == "~" or raw_key == "asciitilde" or raw_key == "dead_tilde"
        or (type(raw_key) == "string" and string_find(raw_key, "tilde"))) then
        sf = true
    end

    if type(clean_key) ~= "string" then
        clean_key = (kc >= 0 and kc <= 255) and CHAR_CACHE[kc] or ""
    end

    return kn, sf, clean_key, raw_key
end

local function _calc_char(kn, sf, kc, clean_key, repr)
    if sf then
        local shifted = _CalcShiftDigitKey[kc]
        if shifted then return shifted end
    elseif kc >= 48 and kc <= 57 then
        return CHAR_CACHE[kc]
    end

    local sym = sf and _CalcShiftKey[kn] or _CalcKey[kn]
    if sym then return sym end

    if kc >= 65 and kc <= 90 then return string.char(kc + 32) end
    if kc >= 97 and kc <= 122 then return CHAR_CACHE[kc] end
    if type(clean_key) == "string" and #clean_key == 1 then
        local b = string_byte(clean_key, 1)
        if b >= 65 and b <= 90 then return CHAR_CACHE[b + 32] end
        if b >= 97 and b <= 122 then return clean_key end
    end
    if type(repr) == "string" and #repr == 1 then
        local b = string_byte(repr, 1)
        if b >= 65 and b <= 90 then return string.char(b + 32) end
        if b >= 97 and b <= 122 then return repr end
    end

    if kc >= 32 and kc <= 126 then
        local ch = CHAR_CACHE[kc]
        if _CalcSymbolSet[ch] then return ch end
    end
    if type(repr) == "string" and #repr == 1 and _CalcSymbolSet[repr] then
        return repr
    end
    return nil
end

local function _is_calc_input_context(ctx, opts)
    return opts and opts.jisuanqi and ctx and type(ctx.input) == "string" and string_sub(ctx.input, 1, 1) == "="
end

local function _is_equal_key(kn, sf, kc, clean_key, repr)
    return not sf and (
        kn == "equal" or kc == 61 or kc == 0xBB or clean_key == "="
        or repr == "=" or repr == "equal"
        or (type(repr) == "string" and string_find(repr:lower(), "equal") ~= nil)
    )
end

local function _is_space_key(kc, clean_key, repr)
    local repr_lower = type(repr) == "string" and repr:lower() or ""
    return kc == 32 or clean_key == " " or repr_lower == "space"
end

local function _is_topup_cancel_key(clean_key, repr, kc)
    if kc == 0xff08 or kc == 0xffff or kc == 0xff1b then return true end
    local key = type(clean_key) == "string" and string_lower(clean_key) or ""
    local raw = type(repr) == "string" and string_lower(repr) or ""
    return key == "backspace" or key == "delete" or key == "escape"
        or raw == "backspace" or raw == "delete" or raw == "escape"
end

local function _is_append_delete_key(clean_key, repr, kc)
    if kc == 0xff08 or kc == 0xffff then return true end
    local key = type(clean_key) == "string" and string_lower(clean_key) or ""
    local raw = type(repr) == "string" and string_lower(repr) or ""
    return key == "backspace" or key == "delete"
        or raw == "backspace" or raw == "delete"
end

local function _is_enter_key(clean_key, repr, kc)
    if kc == 13 or kc == 0xff0d or kc == 0xff8d then return true end
    local key = type(clean_key) == "string" and string_lower(clean_key) or ""
    local raw = type(repr) == "string" and string_lower(repr) or ""
    return key == "return" or key == "enter" or key == "kp_enter"
        or raw == "return" or raw == "enter" or raw == "kp_enter"
end

local function _is_shift_key(clean_key, repr, kc)
    if kc == 0xffe1 or kc == 0xffe2 then return true end
    local key = type(clean_key) == "string" and string_lower(clean_key) or ""
    local raw = type(repr) == "string" and string_lower(repr) or ""
    return key == "shift_l" or key == "shift_r" or key == "shift"
        or raw == "shift_l" or raw == "shift_r" or raw == "shift"
end

local function _is_caps_key(clean_key, repr, kc)
    if kc == 0xffe5 then return true end
    local key = type(clean_key) == "string" and string_lower(clean_key) or ""
    local raw = type(repr) == "string" and string_lower(repr) or ""
    return key == "caps_lock" or key == "capslock" or key == "caps"
        or raw == "caps_lock" or raw == "capslock" or raw == "caps"
end

local function _uppercase_char(clean_key, kc)
    if kc >= 65 and kc <= 90 then return CHAR_CACHE[kc] end
    if type(clean_key) ~= "string" or #clean_key ~= 1 then return nil end
    local b = string_byte(clean_key, 1)
    if b >= 65 and b <= 90 then return clean_key end
    return nil
end

local function _alpha_upper_char(clean_key, kc)
    if kc >= 65 and kc <= 90 then return CHAR_CACHE[kc] end
    if kc >= 97 and kc <= 122 then return CHAR_CACHE[kc - 32] end
    if type(clean_key) ~= "string" or #clean_key ~= 1 then return nil end
    local b = string_byte(clean_key, 1)
    if b >= 65 and b <= 90 then return clean_key end
    if b >= 97 and b <= 122 then return CHAR_CACHE[b - 32] end
    return nil
end

local function _bare_upper_alpha_char(clean_key, kc, repr)
    if kc >= 65 and kc <= 90 then return CHAR_CACHE[kc] end
    if type(clean_key) == "string" and #clean_key == 1 then
        local b = string_byte(clean_key, 1)
        if b >= 65 and b <= 90 then return clean_key end
    end
    if type(repr) == "string" and #repr == 1 then
        local b = string_byte(repr, 1)
        if b >= 65 and b <= 90 then return repr end
    end
    return nil
end

local function _is_caps_on(key_event)
    local ok, value = pcall(function() return key_event:caps() end)
    return ok and value == true
end

local function _repr_has_lock(repr)
    return type(repr) == "string" and string_find(repr, "Lock+", 1, true) ~= nil
end

local function _effective_caps_on(env, key_event)
    local repr = key_event and key_event:repr() or nil
    if _repr_has_lock(repr) or _is_caps_on(key_event) then return true end
    if env and env._caps_lock_on ~= nil then return env._caps_lock_on end
    return false
end

local function _clear_append_candidate(env, ctx)
    state.clear_append(env, ctx)
end

local function _clear_commit_transition_state(env, ctx)
    _topup_clear_queued_keys(env)
    env._af_seed = nil
    env._shift_inline_ascii = nil
    _space_guard_clear(env)
    _clear_append_candidate(env, ctx)
end

local function _set_append_candidate(env, ctx, suffix)
    return state.set_append(env, ctx, suffix)
end

local function _get_append_suffix(env, ctx)
    return state.get_append_suffix(env, ctx)
end

local function _append_candidate_suffix(env, ctx, suffix)
    return state.append_suffix(env, ctx, suffix)
end

local function _pop_append_suffix(env, ctx)
    return state.pop_append_suffix(env, ctx)
end

local function _commit_append_candidate(env, ctx, engine)
    return state.commit_append(env, ctx, engine)
end

local function _ascii_append_char(kn, sf, caps_on, kc, clean_key, repr)
    if kc >= 65 and kc <= 90 then return CHAR_CACHE[kc] end
    if (sf or caps_on) and kc >= 97 and kc <= 122 then return CHAR_CACHE[kc - 32] end
    if kc >= 97 and kc <= 122 then return CHAR_CACHE[kc] end
    if kc >= 48 and kc <= 57 then return CHAR_CACHE[kc] end
    if type(clean_key) == "string" and #clean_key == 1 then
        local b = string_byte(clean_key, 1)
        if (sf or caps_on) and b >= 97 and b <= 122 then return CHAR_CACHE[b - 32] end
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) then
            return clean_key
        end
    end
    if type(repr) == "string" and #repr == 1 then
        local b = string_byte(repr, 1)
        if (sf or caps_on) and b >= 97 and b <= 122 then return CHAR_CACHE[b - 32] end
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) then
            return repr
        end
    end
    return nil
end

local function _ascii_symbol_char(kn, sf, caps_on, kc, clean_key, repr)
    if not (sf or caps_on) then return nil end
    local key_name = kn
    if not key_name or key_name == "" then
        key_name = _KC[kc]
            or _KC_MAP[kc]
            or _KA[type(clean_key) == "string" and clean_key:lower() or clean_key]
            or _KA[type(repr) == "string" and repr:lower() or repr]
    end
    if not key_name then return nil end
    return sf and _CalcShiftKey[key_name] or _CalcKey[key_name]
end

local function _calc_candidate_key(kn, sf, kc, clean_key, repr, allow_space)
    if sf then return nil end
    local repr_lower = type(repr) == "string" and repr:lower() or ""
    local is_first = allow_space and _is_space_key(kc, clean_key, repr)
    local is_second = kn == "semicolon" or kc == 59 or kc == 0xBA or clean_key == ";"
        or repr == "semicolon" or repr == ";" or string_find(repr_lower, "semicolon") ~= nil
    local is_third = kn == "apostrophe" or kc == 39 or kc == 0xDE or clean_key == "'"
        or repr == "apostrophe" or repr == "'" or string_find(repr_lower, "apostrophe") ~= nil
    if is_first then return 0 end
    if is_second then return 1 end
    if is_third then return 2 end
    return nil
end

local function _candidate_type(cand)
    if not cand then return nil end
    local cand_type = cand.type
    if cand.get_genuine then
        local ok, genuine = pcall(function() return cand:get_genuine() end)
        if ok and genuine and genuine.type then cand_type = genuine.type end
    end
    return cand_type
end

_is_completion_candidate = function(cand)
    return _candidate_type(cand) == "completion"
end

local function _has_non_completion_candidate(ctx)
    local selected = ctx:get_selected_candidate()
    if selected then return not _is_completion_candidate(selected) and not _is_raw_input_candidate(ctx, selected) end

    local comp = ctx.composition and ctx.composition:back()
    local menu = comp and comp.menu
    if not menu then return false end

    local ok, cand = pcall(function() return menu:get_candidate_at(0) end)
    return ok and cand and not _is_completion_candidate(cand) and not _is_raw_input_candidate(ctx, cand) or false
end

local function _direct_symbols_completion_is_candidate(env, ctx)
    if env._direct_symbols_fast_leaf then return false end
    return ctx and ctx:get_option("completion") or false
end

local function _is_direct_symbols_candidate(env, ctx, cand)
    if not cand then return false end
    if not _is_completion_candidate(cand) then return true end
    return _direct_symbols_completion_is_candidate(env, ctx)
end

local function _has_direct_symbols_candidate(env, ctx)
    local selected = ctx:get_selected_candidate()
    if selected then return _is_direct_symbols_candidate(env, ctx, selected) end

    local comp = ctx.composition and ctx.composition:back()
    local menu = comp and comp.menu
    if not menu then return false end

    local ok, cand = pcall(function() return menu:get_candidate_at(0) end)
    return ok and _is_direct_symbols_candidate(env, ctx, cand) or false
end

local function _first_direct_symbols_candidate(env, ctx)
    local comp = ctx and ctx.composition and ctx.composition:back()
    local menu = comp and comp.menu
    if not menu then return nil end

    local idx = 0
    while true do
        local ok, cand = pcall(function() return menu:get_candidate_at(idx) end)
        if not ok or not cand then break end
        if _is_direct_symbols_candidate(env, ctx, cand) then
            return cand
        end
        idx = idx + 1
    end
    return nil
end

local function _commit_first_direct_symbols_candidate(env, ctx, engine)
    local first = _first_direct_symbols_candidate(env, ctx)
    if not first then return false end

    local selected = _selected_candidate(ctx)
    if selected and _is_direct_symbols_candidate(env, ctx, selected) then
        ctx:commit()
        return true
    end

    if not engine then return false end
    ctx:clear()
    engine:commit_text(first.text)
    return true
end

local function _direct_symbols_has_real_successor(env, ctx, input)
    input = input or (ctx and ctx.input) or ""
    if not _is_direct_symbols_input(input) then return false end
    if env._direct_symbols_fast_leaf then
        for i = 97, 122 do
            local ch = CHAR_CACHE[i]
            ctx:push_input(ch)
            local pushed_input = ctx.input or ""
            local has_successor = #pushed_input > #input
                and string_sub(pushed_input, 1, #input) == input
                and _has_non_completion_candidate(ctx)
            if #pushed_input > #input and string_sub(pushed_input, 1, #input) == input then
                ctx:pop_input(1)
            end
            if (ctx.input or "") ~= input then return false end
            if has_successor then return true end
        end
        return false
    end
    local code = string_sub(input, 2)
    local state = _symbol_code_state(env.schema_id)
    return state.prefixes[code] == true
end

local function _direct_symbols_known_path(env, input)
    if not _is_direct_symbols_input(input) then return false end
    if env._direct_symbols_fast_leaf then return false end
    local code = string_sub(input, 2)
    local state = _symbol_code_state(env.schema_id)
    return state.codes[code] == true or state.prefixes[code] == true
end

local function _commit_direct_symbols_unique_if_leaf(env, ctx, engine)
    local input = ctx and ctx.input or ""
    if not _is_direct_symbols_input(input) then return false end
    if not _first_direct_symbols_candidate(env, ctx) then return false end
    if _direct_symbols_has_real_successor(env, ctx, input) then return false end
    return _commit_first_direct_symbols_candidate(env, ctx, engine)
end

local function _handle_direct_symbols_alpha_press(env, ctx, key, clean_key, kc, opts)
    if env._tu_streaming or not opts.direct_symbols or not env._alpha[key] then return false end
    local current_input = ctx.input or ""
    if not _is_direct_symbols_input(current_input) then return false end
    local current_candidate = _first_direct_symbols_candidate(env, ctx)
    if not _has_direct_symbols_candidate(env, ctx) and not _direct_symbols_known_path(env, current_input) then return false end

    env._af_seed = nil
    _space_guard_clear(env)

    ctx:push_input(key)
    local pushed_input = ctx.input or ""
    if #pushed_input > #current_input and string_sub(pushed_input, 1, #current_input) == current_input then
        if _has_direct_symbols_candidate(env, ctx) then
            _space_guard_note(env, ctx, current_input, key)
            if _commit_direct_symbols_unique_if_leaf(env, ctx, env.engine) then return kAccepted end
            return kAccepted
        end
        if _direct_symbols_known_path(env, pushed_input) then
            _space_guard_note(env, ctx, current_input, key)
            return kAccepted
        end
        ctx:pop_input(1)
        if (ctx.input or "") ~= current_input then return kAccepted end
        if not current_candidate or not _commit_first_direct_symbols_candidate(env, ctx, env.engine) then return false end
        _topup_push_key(env, ctx, key, clean_key, kc, #current_input - 1)
        return kAccepted
    end

    return kAccepted
end

local function _topup_eval_input(current_input, opts)
    local raw_input = current_input or ""
    local semicolon_input = opts and opts.direct_symbols and _has_semicolon_prefix(raw_input)
    local logical_input = raw_input
    if raw_input:sub(1, 1) == "\\" then
        logical_input = string_sub(raw_input, 2)
    elseif semicolon_input then
        logical_input = string_sub(raw_input, 2)
    end
    local input_len = #logical_input
    local first = (input_len > 0) and string_sub(logical_input, 1, 1) or ""
    local prev = (input_len > 0) and string_sub(logical_input, -1) or ""
    return {
        raw_input = raw_input,
        raw_len = #raw_input,
        input = logical_input,
        input_len = input_len,
        first = first,
        prev = prev,
        semicolon_input = semicolon_input,
    }
end

local function _space_guard_selected_current(ctx, input_len)
    local cand = _selected_candidate(ctx)
    if not cand then return false end
    local cand_end = cand._end
    if type(cand_end) == "number" and cand_end > 0 and cand_end < input_len then
        return false
    end
    local comp = ctx.composition and ctx.composition:back()
    local seg_end = comp and comp._end
    if type(seg_end) == "number" and seg_end > 0 and seg_end < input_len then
        return false
    end
    return true
end

local function _space_guard_hold_current(env, ctx, current)
    if not current or current == "" or #current < (env._tu_max or 6) then return false end
    if _space_guard_selected_current(ctx, #current) then return false end
    if env._space_guard_refreshed_input == current then return true end
    if platform.refresh(ctx, env.engine.schema.config) then
        env._space_guard_refreshed_input = current
        return true
    end
    return false
end

local function _space_guard_process(env, ctx, key_event, clean_key, repr, kc, no_modifier)
    if not (env._space_guard_enabled and no_modifier and _is_space_key(kc, clean_key, repr)) then
        return nil
    end

    local input_text = ctx and (ctx.input or "") or ""
    if input_text ~= "" then
        if string_find(input_text, "`", 1, true) then
            return nil
        end
        if env._rx_prefix and env._rx_prefix[string_sub(input_text, 1, 1)] then
            return nil
        end
    end

    if key_event:release() then
        local expected = env._space_guard_wait
        if not expected then return nil end
        env._space_guard_wait = nil
        local current = ctx.input or ""
        local selected_current = ctx:is_composing() and _space_guard_selected_current(ctx, #current)
        if current == expected and selected_current then
            _commit_selected_candidate(ctx)
        end
        _space_guard_clear(env)
        return kAccepted
    end

    local expected = env._space_guard_input
    if not expected or expected == "" or not ctx:is_composing() then
        _space_guard_clear(env)
        return nil
    end

    local current = ctx.input or ""
    if current ~= expected then
        env._space_guard_wait = expected
        return kAccepted
    end
    if _space_guard_hold_current(env, ctx, current) then
        env._space_guard_wait = expected
        return kAccepted
    end

    _space_guard_clear(env)
    return nil
end

local function _is_reverse_input(env, input)
    if not input or input == "" or not env._rx_prefix then return false end
    return env._rx_prefix[string_sub(input, 1, 1)] == true
end

local function _is_alpha_key(env, key, clean_key, kc)
    if (kc >= 65 and kc <= 90) or (kc >= 97 and kc <= 122) then return true end
    if type(key) == "string" and env._alpha[string_lower(key)] then return true end
    if type(clean_key) == "string" and env._alpha[string_lower(clean_key)] then return true end
    return false
end

local function _passthrough_alpha_key(env, ctx, sf, key, clean_key, kc)
    if not _is_alpha_key(env, key, clean_key, kc) then return false end
    return sf or _is_reverse_input(env, ctx.input)
end

local function _shift_inline_alpha_key(env, ctx, sf, key, clean_key, kc)
    if not env._shift_inline_ascii then return false end
    if sf or not ctx:is_composing() or (ctx.input or "") == "" then
        env._shift_inline_ascii = nil
        return false
    end
    if not _is_alpha_key(env, key, clean_key, kc) then
        env._shift_inline_ascii = nil
        return false
    end
    return true
end

local function _topup_fixed_rule_would_commit(env, current_input, key, opts)
    local eval = _topup_eval_input(current_input, opts)
    local input_len = eval.input_len
    if input_len < 1 then return false end
    if eval.semicolon_input then return false end

    local first = eval.first
    local prev = eval.prev
    local is_tu = env._tu_set[key]
    local is_ptu = env._tu_set[prev]
    local is_ftu = env._tu_set[first]

    if env._tu_cmd and is_ftu then return false end
    if input_len >= (env._tu_max or 6) then return true end
    if is_ptu and not is_tu then return true end
    return input_len >= (env._tu_min or 4) and not is_ptu and not is_tu
end

local function _topup_auto_fallback(env, ctx, key, clean_key, kc, opts)
    if env._tu_streaming or not opts.auto_fallback or not env._alpha[key] then return false end
    local zzc_stage = ctx and ctx.get_property and (ctx:get_property("_xmjd6_zzc_stage") or "") or ""
    local zzc_mode = ctx and ctx.get_property and (ctx:get_property("_xmjd6_zzc_mode") or "") or ""
    if zzc_processor and zzc_processor.is_active and zzc_processor.is_active(ctx)
        and zzc_stage == "collect"
        and zzc_mode == "make"
        and type(ctx.input) == "string"
        and ctx.input:sub(1, 1) == "\\" then
        return false
    end
    local current_input = ctx.input
    local eval = _topup_eval_input(current_input, opts)
    if eval.raw_len < 1 then return false end
    if _topup_fixed_rule_would_commit(env, current_input, key, opts) then return false end
    if not _has_non_completion_candidate(ctx) then return false end
    if not _topup_ready(env, ctx) then return kAccepted end

    env._af_seed = nil
    _space_guard_clear(env)

    ctx:push_input(key)
    if _has_non_completion_candidate(ctx) then
        _space_guard_note(env, ctx, current_input, key)
        return kAccepted
    end

    local pushed_input = ctx.input or ""
    if #pushed_input <= #current_input or string_sub(pushed_input, 1, #current_input) ~= current_input then
        return kAccepted
    end

    ctx:pop_input(1)
    if (ctx.input or "") ~= current_input then return kAccepted end
    if not _space_guard_selected_current(ctx, #current_input) and not _has_non_completion_candidate(ctx) then
        return kAccepted
    end

    if zzc_processor and zzc_processor.is_active and zzc_processor.is_active(ctx) then
        if zzc_processor.capture_current_candidate and zzc_processor.capture_current_candidate(ctx, key) then
            return kAccepted
        end
        return false
    end
    if not _commit_selected_non_completion(ctx) then return false end
    _topup_push_key(env, ctx, key, clean_key, kc, eval.input_len)
    return kAccepted
end

local function _commit_menu_index(ctx, engine, idx)
    local comp = ctx.composition:back()
    if not comp then return false end
    local menu = comp.menu
    if not menu then return false end
    local cand = menu:get_candidate_at(idx)
    if cand then
        ctx:clear()
        engine:commit_text(cand.text)
        return true
    end
    return false
end

local function _smart_process(key_event, env, kn, sf, clean_key, opts)
    if key_event:alt() or key_event:super() then return kNoop end
    local ctx = env.engine.context

    if kn == "grave" and not sf and not key_event:ctrl() then
        if key_event:release() then return kAccepted end
        ctx:push_input("`")
        return kAccepted
    end

    if not key_event:release() and not sf then
        local input = ctx.input
        if input == "-" then
            local kc = key_event.keycode
            if kc >= 48 and kc <= 57 then
                ctx:commit()
                env.engine:commit_text(CHAR_CACHE[kc])
                return kAccepted
            end
        end
    end

    if not key_event:release() and _is_calc_input_context(ctx, opts) and not _is_space_key(key_event.keycode, clean_key, key_event:repr()) then
        local calc_ch = _calc_char(kn, sf, key_event.keycode, clean_key, key_event:repr())
        if calc_ch then
            if calc_ch == "=" and (ctx.input or "") == "=" then
                if env._calc_equal_allow_next then
                    ctx:push_input(calc_ch)
                    env._calc_equal_allow_next = nil
                else
                    env._calc_equal_allow_next = false
                end
                return kAccepted
            end
            env._calc_equal_allow_next = nil
            ctx:push_input(calc_ch)
            return kAccepted
        end
    end

    local direct_symbols_off = not opts.direct_symbols
    
    if key_event:release() then
        if kn == "equal" then
            env._calc_equal_allow_next = (ctx.input or "") == "="
        end
        if kn and env._sw == kn then env._sw = nil; return kAccepted end
        if kn and env._dc == kn then env._dc = nil; return kAccepted end
        if direct_symbols_off then
            env._dc = nil
        end
        return kNoop
    end

    env._dc = nil
    if kn == "period" and not sf and not ctx:is_composing() then
        if env._standalone_period_after_digit then
            env._standalone_period_after_digit = nil
            _clear_commit_transition_state(env, ctx)
            env.engine:commit_text(".")
            return kAccepted
        end
        _clear_commit_transition_state(env, ctx)
        env.engine:commit_text("。")
        return kAccepted
    end

    if kn == "period" and not sf and ctx:is_composing() then
        _clear_commit_transition_state(env, ctx)
        ctx:commit()
        env.engine:commit_text("。")
        env._dc = kn
        return kAccepted
    end

    if env._tu_streaming and not sf and (kn == "semicolon" or kn == "apostrophe") then
        return kNoop
    end

    if not env._tu_streaming and not opts.smarttwo and not direct_symbols_off and not sf and kn == "semicolon" then
        local inp = ctx.input
        if inp ~= "" and not string_find(inp, ";", 1, true) then 
             if ctx:has_menu() and _selected_is_non_completion(ctx) then
                _commit_selected_non_completion(ctx); ctx:push_input(";"); env._sw = kn; return kAccepted
             end
        end
    end

    if ctx:has_menu() and opts.smarttwo then
        if (kn == "semicolon" or kn == "apostrophe") and not sf then
            if env._tu_streaming then return kNoop end
            local comp = ctx.composition:back()
            if comp then
                local idx = (kn == "semicolon") and 1 or 2
                if _commit_menu_index(ctx, env.engine, idx) then return kAccepted end
                if not _selected_candidate(ctx) then
                     if #ctx.input > 1 then ctx:commit(); return kAccepted end
                else
                     if _commit_selected_non_completion(ctx) then return kAccepted end
                end
            end
        end
    end

    if direct_symbols_off then
        if kn == "period" and not sf and not ctx:is_composing() then return kNoop end
        if not (kn == "equal" and not sf and opts.jisuanqi) then
             if _tdc(_SymCN, kn, sf, env.engine, ctx) then
                local sym_cfg = _SymCN[kn]
                local sym = sym_cfg and (sf and sym_cfg.shift or sym_cfg.plain) or nil
                _guard_shift_symbol_release(env, sf)
                env._dc = kn
                return kAccepted
             end
        end
        
        if not env._tu_streaming and ctx:has_menu() and not _is_alpha_key(env, kn, clean_key, key_event.keycode) then
            local seg = ctx.composition:back()
            if seg and seg.menu:get_candidate_at(0) and not seg.menu:get_candidate_at(1) then
                local input = ctx.input
                if input ~= ";" and input ~= "；" then
                    if _commit_selected_non_completion(ctx) then return kAccepted end
                end
            end
        end
    end

    if not opts.jisuanqi then
        if (kn == "equal" or kn == "minus") and ctx:has_menu() and not sf then return kNoop end
        if _tdc(_JsOff, kn, sf, env.engine, ctx) then
            _guard_shift_symbol_release(env, sf)
            return kAccepted
        end
    end

    if not opts.smarttwo then
        if kn == "semicolon" and not sf then return kNoop end
        if kn == "apostrophe" then return kNoop end
        if _tdc(_SmOff, kn, sf, env.engine, ctx) then
            _guard_shift_symbol_release(env, sf)
            return kAccepted
        end
    end

    return kNoop
end

local function processor(key_event, env)
    local kn, sf, clean_key, repr = _resolve_key(key_event, env)
    local ctx = env.engine.context
    local kc = key_event.keycode
    if ctx:is_composing() and _is_memory_tool_input(ctx.input) and not key_event:release() then
        local alpha = _alpha_upper_char(clean_key, kc) or _uppercase_char(clean_key, kc)
        if _is_space_key(kc, clean_key, repr) or alpha then
            ctx:clear()
            _topup_clear_queued_keys(env)
            env._af_seed = nil
            _space_guard_clear(env)
            return kNoop
        end
    end
    if ctx:is_composing() and _get_append_suffix(env, ctx) and _is_append_delete_key(clean_key, repr, kc) then
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        if key_event:release() then return kAccepted end
        if _pop_append_suffix(env, ctx) then return kAccepted end
    end
    if _is_topup_cancel_key(clean_key, repr, kc) then
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        _space_guard_clear(env)
        _clear_append_candidate(env, ctx)
        return kNoop
    end
    if _is_enter_key(clean_key, repr, kc) then
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        _space_guard_clear(env)
        if key_event:release() then return kAccepted end
        if _commit_append_candidate(env, ctx, env.engine) then return kAccepted end
        _clear_append_candidate(env, ctx)
        local input = ctx.input
        if ctx:is_composing() and input and input ~= "" then
            ctx:clear()
            env.engine:commit_text(input)
            return kAccepted
        end
        return kNoop
    end
    if _is_shift_key(clean_key, repr, kc) then
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        _space_guard_clear(env)
        if key_event:release() and env._shift_symbol_release_guard then
            env._shift_symbol_release_guard = nil
            return kAccepted
        end
        if not key_event:release() then
            env._shift_symbol_release_guard = nil
        end
        return kNoop
    end
    if _is_caps_key(clean_key, repr, kc) then
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        _space_guard_clear(env)
        if _repr_has_lock(repr) then
            env._caps_lock_on = true
        elseif key_event:release() then
            env._caps_lock_on = false
        end
        if env._caps_blocked then
            if key_event:release() then env._caps_blocked = nil end
            if ctx:is_composing() then return kAccepted end
            env._caps_blocked = nil
            return kNoop
        end
        if ctx:is_composing() then
            env._caps_blocked = true
            return kAccepted
        end
        return kNoop
    end
    local ascii_mode = ctx:get_option("ascii_mode")
    local no_modifier = not key_event:ctrl() and not key_event:alt() and not key_event:super()
    local plain_digit_key = (not ascii_mode and no_modifier and not sf and not key_event:release()
        and not ctx:is_composing() and (ctx.input or "") == "")
        and _digit_char(clean_key, kc, repr) or nil
    env._standalone_period_after_digit = (no_modifier and not sf and not key_event:release()
        and kn == "period" and not ctx:is_composing() and env._last_plain_digit_key) or nil
    if plain_digit_key then
        env._last_plain_digit_key = true
    elseif not key_event:release() then
        env._last_plain_digit_key = nil
    end
    local caps_on = _effective_caps_on(env, key_event)
    local bare_upper = (not ascii_mode and not sf and not caps_on and no_modifier and not key_event:release())
        and _bare_upper_alpha_char(clean_key, kc, repr) or nil
    if bare_upper and ((ctx.input or "") == "" or env._shift_inline_ascii) then
        env._shift_inline_ascii = true
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        _space_guard_clear(env)
        ctx:push_input(bare_upper)
        return kAccepted
    end
    if not ascii_mode and sf and no_modifier and _is_alpha_key(env, kn, clean_key, kc) then
        env._shift_inline_ascii = true
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        _space_guard_clear(env)
        return kNoop
    end
    if ascii_mode or not ctx:is_composing() or (ctx.input or "") == "" then
        env._shift_inline_ascii = nil
    elseif not key_event:release() and no_modifier and not caps_on
        and _shift_inline_alpha_key(env, ctx, sf, kn, clean_key, kc) then
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        _space_guard_clear(env)
        return kNoop
    end
    if not ascii_mode and no_modifier and ctx:is_composing() and _get_append_suffix(env, ctx) then
        if key_event:release() then return kAccepted end
        local ch = _ascii_append_char(kn, sf, caps_on, kc, clean_key, repr)
            or (caps_on and _ascii_symbol_char(kn, false, true, kc, clean_key, repr) or nil)
        if ch and _append_candidate_suffix(env, ctx, ch) then return kAccepted end
    end
    local append_alpha = nil
    if not ascii_mode and no_modifier and ctx:is_composing() then
        if caps_on then
            append_alpha = _alpha_upper_char(clean_key, kc)
        else
            append_alpha = _uppercase_char(clean_key, kc)
        end
    end
    local append_suffix = append_alpha
    if not append_suffix and not ascii_mode and no_modifier and ctx:is_composing() and caps_on then
        append_suffix = _ascii_symbol_char(kn, false, true, kc, clean_key, repr)
    end
    if append_suffix then
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        _space_guard_clear(env)
        if key_event:release() then return kAccepted end
        if _set_append_candidate(env, ctx, append_suffix) then return kAccepted end
    end
    local uppercase = (not ascii_mode and not sf and no_modifier and caps_on) and _uppercase_char(clean_key, kc) or nil
    if uppercase then
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        _space_guard_clear(env)
        if key_event:release() then return kAccepted end
        local cold_code_key = _plain_code_key(env, CHAR_CACHE[kc] or clean_key, clean_key, kc)
        if _cold_start_push_code_key(env, ctx, key_event, cold_code_key, false, false) then
            return kAccepted
        end
        if ctx:is_composing() then ctx:commit() end
        env.engine:commit_text(uppercase)
        return kAccepted
    end
    local caps_symbol = (not ascii_mode and no_modifier and caps_on)
        and _ascii_symbol_char(kn, sf, caps_on, kc, clean_key, repr) or nil
    if caps_symbol then
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        _space_guard_clear(env)
        if key_event:release() then return kAccepted end
        if ctx:is_composing() then ctx:commit() end
        env.engine:commit_text(caps_symbol)
        return kAccepted
    end
    if ascii_mode then
        _space_guard_clear(env)
        return kNoop
    end
    if no_modifier and not env._tu_pending_key and not key_event:release() and not sf and not caps_on
        and not ctx:is_composing() and (ctx.input or "") == "" then
        local cold_plain_key = _plain_code_key(env, CHAR_CACHE[kc] or clean_key, clean_key, kc)
        if cold_plain_key then
            env._cold_code_guard = nil
            _push_code_input(env, ctx, cold_plain_key)
            return kAccepted
        end
    end
    local opts = {
        smarttwo = ctx:get_option("smarttwo"),
        direct_symbols = ctx:get_option("direct_symbols"),
        jisuanqi = ctx:get_option("jisuanqi"),
        auto_fallback = ctx:get_option("auto_fallback"),
    }

    local space_result = (not sf) and _space_guard_process(env, ctx, key_event, clean_key, repr, kc, no_modifier) or nil
    if space_result then return space_result end

    local sm_result = _smart_process(key_event, env, kn, sf, clean_key, opts)
    if sm_result == kAccepted then
        _space_guard_clear(env)
        return kAccepted
    end

    if key_event:release() then
        if _topup_handle_queued_release(env, ctx, clean_key, kc) then return kAccepted end
        if ctx:has_menu() then
            if kc == 0xffe3 or kc == 0xffe4 then -- Ctrl
                 if _commit_menu_index(ctx, env.engine, 1) then return kAccepted end
                 return kAccepted
            elseif kc == 0xffe9 or kc == 0xffea then -- Alt
                 if _commit_menu_index(ctx, env.engine, 2) then return kAccepted end
                 return kAccepted
            end
        end
        return kNoop
    end

    if key_event:ctrl() or key_event:alt() then
        _topup_clear_pending_key(env)
        env._af_seed = nil
        _space_guard_clear(env)
        return kNoop
    end
    if kc < 32 or kc >= 127 then
        _topup_clear_pending_key(env)
        env._af_seed = nil
        if not _is_space_key(kc, clean_key, repr) then _space_guard_clear(env) end
        return kNoop
    end
    
    local raw_key = CHAR_CACHE[kc] or clean_key
    local plain_code_key = _plain_code_key(env, raw_key, clean_key, kc)
    local key = plain_code_key or raw_key
    local is_code_key = plain_code_key ~= nil or (env._alpha and env._alpha[key])
    if _cold_start_push_code_key(env, ctx, key_event, plain_code_key, sf, caps_on) then
        return kAccepted
    end
    if env._tu_pending_key and not _topup_is_pending_key_event(env, key, kc) and not is_code_key then
        _topup_clear_pending_key(env)
        env._af_seed = nil
    end
    if _topup_flush_plain_alpha_press(env, ctx, key_event, key, sf, caps_on) then
        return kAccepted
    end
    if _passthrough_alpha_key(env, ctx, sf, key, clean_key, kc) then
        return kNoop
    end

    if opts.direct_symbols and ctx.input == ";" and env._alpha[key] then
        _push_code_input(env, ctx, key)
        if _commit_direct_symbols_unique_if_leaf(env, ctx, env.engine) then return kAccepted end
        return kAccepted
    end

    local direct_symbols_result = _handle_direct_symbols_alpha_press(env, ctx, key, clean_key, kc, opts)
    if direct_symbols_result then return direct_symbols_result end

    if is_code_key and not _topup_is_pending_key_event(env, key, kc) and _topup_flush_key(env, ctx) then
        _push_code_input(env, ctx, key)
        return kAccepted
    end

    if _topup_auto_fallback(env, ctx, key, clean_key, kc, opts) then
        return kAccepted
    end

    if not env._tu_streaming and is_code_key then
        local current_input = ctx.input
        local eval = _topup_eval_input(current_input, opts)
        local input_len = eval.input_len
        local min_len = env._tu_min
        
        local prev = eval.prev
        local first = (input_len > 0) and eval.first or key
        
        local is_tu = env._tu_set[key]
        local is_ptu = env._tu_set[prev]
        local is_ftu = env._tu_set[first]

        if not eval.semicolon_input and not (env._tu_cmd and is_ftu) then
            if is_ptu and not is_tu then
                env._xmjd6_zzc_follow_key = key
                local executed, consumed_follow = _topup_exec(env)
                if not executed then return kAccepted end
                env._xmjd6_zzc_follow_key = nil
                if not consumed_follow then
                    _topup_push_key(env, ctx, key, clean_key, kc, input_len)
                end
                return kAccepted
            elseif not is_ptu and not is_tu and input_len >= min_len then
                env._xmjd6_zzc_follow_key = key
                local executed, consumed_follow = _topup_exec(env)
                if not executed then return kAccepted end
                env._xmjd6_zzc_follow_key = nil
                if not consumed_follow then
                    _topup_push_key(env, ctx, key, clean_key, kc, input_len)
                end
                return kAccepted
            elseif input_len >= env._tu_max then
                env._xmjd6_zzc_follow_key = key
                local executed, consumed_follow = _topup_exec(env)
                if not executed then return kAccepted end
                env._xmjd6_zzc_follow_key = nil
                if not consumed_follow then
                    _topup_push_key(env, ctx, key, clean_key, kc, input_len)
                end
                return kAccepted
            end
        end
    end

    if is_code_key and no_modifier and not sf and not caps_on and not _is_reverse_input(env, ctx.input) then
        _space_guard_note(env, ctx, ctx.input or "", key)
    else
        _space_guard_clear(env)
    end
    return kNoop
end

local function init(env)
    local config = env.engine.schema.config

    env._ks = {}
    env._sw = nil
    env._dc = nil
    
    local ab = config:get_string("speller/alphabet") or "abcdefghijklmnopqrstuvwxyz"
    env._alpha = {}
    for i = 1, #ab do
        local ch = string_sub(ab, i, i)
        env._alpha[ch] = true
    end
    
    env._tu_set = _s2set(config:get_string("topup/topup_with") or "")
    env._tu_min = config:get_int("topup/min_length") or 4
    env._tu_max = config:get_int("topup/max_length") or 6
    env._tu_ac = config:get_bool("topup/auto_clear") or false
    env._tu_cmd = config:get_bool("topup/topup_command") or false
    env._tu_streaming = config:get_bool("translator/enable_sentence") or false
    local schema_id = env.engine.schema.schema_id or ""
    env._rx_prefix = _collect_reverse_prefixes(config, schema_id, true)
    state.init_append(env, schema_id)
    env._tc = nil
    env._tc_pending = true
    env._cold_code_guard = true
    env._space_guard_enabled = config:get_string("xmjd6/space_guard") ~= "off"
    env._direct_symbols_fast_leaf = _config_bool(config, "xmjd6/direct_symbols_fast_leaf", true)
    _space_guard_clear(env)
    _topup_clear_queued_keys(env)
    env._af_seed = nil
    env._caps_blocked = nil
    env._caps_lock_on = nil
    env._shift_symbol_release_guard = nil
    env._shift_inline_ascii = nil
    env._calc_equal_allow_next = nil

    registry.register("processor", function()
        symbol_code_state = nil
        _space_guard_clear(env)
        _topup_clear_queued_keys(env)
        env._af_seed = nil
        env._calc_equal_allow_next = nil
        env._caps_lock_on = nil
        env._shift_inline_ascii = nil
        return true
    end)

    collectgarbage("step", 80)
end

local function fini(env)
    env._ks = nil
    env._alpha = nil
    env._tu_set = nil
    _topup_clear_queued_keys(env)
    env._rx_prefix = nil
    env._append_input_key = nil
    env._append_suffix_key = nil
    env._af_seed = nil
    env._cold_code_guard = nil
    env._space_guard_enabled = nil
    env._direct_symbols_fast_leaf = nil
    _space_guard_clear(env)
    env._caps_blocked = nil
    env._caps_lock_on = nil
    env._shift_symbol_release_guard = nil
    env._shift_inline_ascii = nil
    env._calc_equal_allow_next = nil
    -- 主动GC：释放资源后回收内存
    collectgarbage("step", 200)
end

return { init = init, func = processor, fini = fini }
