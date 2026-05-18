-- 天行键统一按键处理器
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：fjerdsjkbs-4

local string_sub = string.sub
local string_byte = string.byte
local string_match = string.match
local string_find = string.find
local floor = math.floor
local type = type

local kAccepted = 1
local kNoop = 2

local ctx_option_handlers = setmetatable({}, { __mode = "k" })

local CHAR_CACHE = {}
for i = 0, 255 do CHAR_CACHE[i] = string.char(i) end

local function _s2set(str)
    local t = {}
    if type(str) ~= "string" then return t end
    for i = 1, #str do t[string_sub(str,i,i)] = true end
    return t
end

local _SymCN = {
    ["slash"]      = { plain = "/", shift = "？" },
    ["backslash"]  = { plain = "、", shift = "·" },
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
local _SmOff = { ["semicolon"] = { plain = ";", shift = "：" }, ["apostrophe"] = { plain = "'", shift = "\"" } }
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

local _KN_MAP = {
    ["semicolon"]=true, ["apostrophe"]=true, ["comma"]=true, ["period"]=true,
    ["slash"]=true, ["minus"]=true, ["equal"]=true, 
    ["bracketleft"]=true, ["bracketright"]=true, ["backslash"]=true, ["grave"]=true
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
local _CalcSymbolSet = _s2set("+-*/%^#=~<>(){}[].,:$\\|&\"_? ")

local function _tdc(map, kn, sf, engine, ctx)
    local c = map[kn]
    if not c then return false end
    local sym = sf and c.shift or c.plain
    if not sym then return false end
    if ctx:is_composing() then ctx:commit() end
    engine:commit_text(sym)
    return true
end

local function _topup_exec(env)
    if env._tc then
        env._tc = env._tc + 1
        if env._tc > 200 then env._tc = 81 end
        if env._tc > 80 and env._tc % 3 ~= 0 then return end
    elseif env._tc_pending then
        env._tc_pending = false
        local rv = env.engine.context:get_property("_rvk")
        if not rv or rv == "" then env._tc = 0 end
    end
    
    if not env.engine.context:get_selected_candidate() then
        if env._tu_ac then env.engine.context:clear() end
    else
        env.engine.context:commit()
    end
end

local function _topup_queue_key(env, key, clean_key, kc)
    env._tu_pending_key = key
    env._tu_pending_clean = clean_key
    env._tu_pending_kc = kc
end

local function _topup_flush_key(env, ctx)
    local key = env._tu_pending_key
    if not key then return false end
    env._tu_pending_key = nil
    env._tu_pending_clean = nil
    env._tu_pending_kc = nil
    ctx:push_input(key)
    return true
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
    if kc >= 48 and kc <= 57 then return CHAR_CACHE[kc] end
    if kc >= 65 and kc <= 90 then return string.char(kc + 32) end
    if kc >= 97 and kc <= 122 then return CHAR_CACHE[kc] end

    local sym = sf and _CalcShiftKey[kn] or _CalcKey[kn]
    if sym then return sym end

    if kc >= 32 and kc <= 126 then
        local ch = CHAR_CACHE[kc]
        if _CalcSymbolSet[ch] then return ch end
    end
    if type(repr) == "string" and #repr == 1 and _CalcSymbolSet[repr] then
        return repr
    end
    return nil
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

local function _has_menu_candidates(ctx)
    if ctx:has_menu() then
        return true
    end
    local comp = ctx.composition:back()
    return comp and comp.menu and comp.menu:get_candidate_at(0) ~= nil
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

    local ds_on = not opts.direct_symbols
    
    if key_event:release() then
        if kn and env._sw == kn then env._sw = nil; return kAccepted end
        if ds_on then
            if kn and env._dc == kn then env._dc = nil; return kAccepted end
            env._dc = nil
        end
        
        if not ds_on then
            local input = ctx.input
            if #input == 2 and string_byte(input, 1) == 59 then 
                local b2 = string_byte(input, 2)
                if b2 >= 97 and b2 <= 122 then
                    if ctx:has_menu() then
                        local comp = ctx.composition:back()
                        if comp and comp.menu and not comp.menu:get_candidate_at(1) then
                             local cand = ctx:get_selected_candidate()
                             if cand and cand.text ~= ";" and cand.text ~= "；" then ctx:commit(); return kAccepted end
                        end
                    end
                end
            end
        end
        return kNoop
    end

    env._dc = nil

    if env._tu_streaming and not sf and (kn == "semicolon" or kn == "apostrophe") then
        return kNoop
    end

    if not env._tu_streaming and not opts.smarttwo and not ds_on and not sf and kn == "semicolon" then
        local inp = ctx.input
        if inp ~= "" and not string.find(inp, ";", 1, true) then 
             if ctx:has_menu() and ctx:get_selected_candidate() then
                ctx:commit(); ctx:push_input(";"); env._sw = kn; return kAccepted
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
                if not ctx:get_selected_candidate() then
                     if #ctx.input > 1 then ctx:commit(); return kAccepted end
                else
                     ctx:commit(); return kAccepted
                end
            end
        end
    end

    if ds_on then
        if not (kn == "equal" and not sf and opts.jisuanqi) then
             if _tdc(_SymCN, kn, sf, env.engine, ctx) then env._dc = kn; return kAccepted end
        end
        
        if not env._tu_streaming and ctx:has_menu() then
            local seg = ctx.composition:back()
            if seg and seg.menu:get_candidate_at(0) and not seg.menu:get_candidate_at(1) then
                local input = ctx.input
                if input ~= ";" and input ~= "；" then
                    ctx:commit()
                    return kAccepted
                end
            end
        end
    end

    if not opts.jisuanqi then
        if (kn == "equal" or kn == "minus") and ctx:has_menu() and not sf then return kNoop end
        if _tdc(_JsOff, kn, sf, env.engine, ctx) then return kAccepted end
    end

    if not opts.smarttwo then
        if kn == "semicolon" and not sf then return kNoop end
        if _tdc(_SmOff, kn, sf, env.engine, ctx) then return kAccepted end
    end

    return kNoop
end

local function processor(key_event, env)
    local kn, sf, clean_key, repr = _resolve_key(key_event, env)
    local ctx = env.engine.context
    local opts = {
        smarttwo = ctx:get_option("smarttwo"),
        direct_symbols = ctx:get_option("direct_symbols"),
        jisuanqi = ctx:get_option("jisuanqi"),
        auto_fallback = ctx:get_option("auto_fallback"),
    }

    local sm_result = _smart_process(key_event, env, kn, sf, clean_key, opts)
    if sm_result == kAccepted then return kAccepted end

    local kc = key_event.keycode

    if key_event:release() then
        if env._tu_pending_key and (clean_key == env._tu_pending_clean or kc == env._tu_pending_kc) then
            _topup_flush_key(env, ctx)
            return kAccepted
        end
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

    if key_event:ctrl() or key_event:alt() then return kNoop end
    if kc < 32 or kc >= 127 then return kNoop end
    
    local key = CHAR_CACHE[kc] or clean_key
    _topup_flush_key(env, ctx)

    if opts.direct_symbols and ctx.input == ";" and env._alpha[key] then
        ctx:push_input(key)
        
        if ctx:has_menu() then
            local seg = ctx.composition:back()
            if seg and seg.menu:get_candidate_at(0) and not seg.menu:get_candidate_at(1) then
                ctx:commit()
            end
        end
        
        return kAccepted
    end

    if not env._tu_streaming and opts.auto_fallback and env._alpha[key] then
        local current_input = ctx.input
        if #current_input >= 1 and ctx:get_selected_candidate() then
            if not (opts.direct_symbols and current_input == ";") then
                ctx:push_input(key)
                if ctx:get_selected_candidate() then return kAccepted end
                ctx:pop_input(1); ctx:commit(); ctx:push_input(key)
                return kAccepted
            end
        end
    end

    if not env._tu_streaming and env._alpha[key] then
        local current_input = ctx.input
        local input_len = #current_input
        local min_len = env._tu_min
        
        local prev = (input_len > 0) and string_sub(current_input, -1) or ""
        local first = (input_len > 0) and string_sub(current_input, 1, 1) or key
        
        local is_tu = env._tu_set[key]
        local is_ptu = env._tu_set[prev]
        local is_ftu = env._tu_set[first]

        if not (env._tu_cmd and is_ftu) then
             if not (opts.direct_symbols and input_len > 0 and string_byte(current_input, 1) == 59) then
                if is_ptu and not is_tu then
                    _topup_exec(env)
                    if input_len >= 3 then
                        _topup_queue_key(env, key, clean_key, kc)
                    else
                        ctx:push_input(key)
                    end
                    return kAccepted
                elseif not is_ptu and not is_tu and input_len >= min_len then
                    _topup_exec(env)
                    _topup_queue_key(env, key, clean_key, kc)
                    return kAccepted
                elseif input_len >= env._tu_max then
                    _topup_exec(env)
                    _topup_queue_key(env, key, clean_key, kc)
                    return kAccepted
                end
             end
        end
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
    for i = 1, #ab do env._alpha[string_sub(ab,i,i)] = true end
    
    env._tu_set = _s2set(config:get_string("topup/topup_with") or "")
    env._tu_min = config:get_int("topup/min_length") or 4
    env._tu_max = config:get_int("topup/max_length") or 6
    env._tu_ac = config:get_bool("topup/auto_clear") or false
    env._tu_cmd = config:get_bool("topup/topup_command") or false
    env._tu_streaming = config:get_bool("translator/enable_sentence") or false
    env._tc = nil
    env._tc_pending = true
    env._tu_pending_key = nil
    env._tu_pending_clean = nil
    env._tu_pending_kc = nil

    local ctx = env.engine.context
    if env._option_handler and ctx.option_update_notifier then
        pcall(function() ctx.option_update_notifier:disconnect(env._option_handler) end)
    end
    if ctx_option_handlers[ctx] and ctx.option_update_notifier then
        pcall(function() ctx.option_update_notifier:disconnect(ctx_option_handlers[ctx]) end)
    end
    env._option_handler = nil
    ctx_option_handlers[ctx] = nil

    collectgarbage("collect")
end

local function fini(env)
    local ctx = env.engine and env.engine.context
    if ctx then
        if env._option_handler and ctx.option_update_notifier then
            pcall(function() ctx.option_update_notifier:disconnect(env._option_handler) end)
        end
        ctx_option_handlers[ctx] = nil
    end
    env._option_handler = nil
    env._ks = nil
    env._alpha = nil
    env._tu_set = nil
    env._tu_pending_key = nil
    env._tu_pending_clean = nil
    env._tu_pending_kc = nil
    -- 主动GC：释放资源后回收内存
    collectgarbage("step", 200)
end

return { init = init, func = processor, fini = fini }
