-- 天行键统一按键处理器
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-03-17

local string_sub = string.sub
local string_byte = string.byte
local floor = math.floor
local type = type

local kAccepted = 1
local kNoop = 2

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

local function _resolve_key(key_event, env)
    local kc = key_event.keycode
    local sf = key_event:shift()
    
    if (kc == 43) or (kc == 95) or (kc == 123) or (kc == 125) or (kc == 124) or 
       (kc == 58) or (kc == 34) or (kc == 63) or (kc == 126) or (kc == 60) or (kc == 62) then
        sf = true
    end

    local kn = _KC_MAP[kc]
    if not kn then
        if not ((kc >= 97 and kc <= 122) or (kc >= 65 and kc <= 90) or (kc >= 48 and kc <= 57)) then
            local repr = key_event:repr()
            if repr and _KN_MAP[repr] then kn = repr end
        end
    end
    
    local clean_key = (kc >= 0 and kc <= 255) and CHAR_CACHE[kc] or ""
    
    if not key_event:release() then
        if kn then 
            env._ks = env._ks or {}
            env._ks[kc] = sf
        end
    else
        if env._ks and env._ks[kc] ~= nil then
            sf = env._ks[kc]
            env._ks[kc] = nil
        end
    end
    
    return kn, sf, clean_key
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
                local ps = env.engine.schema.page_size or 5
                if ps == 0 then ps = 5 end
                local si = comp.selected_index
                local pst = floor(si / ps) * ps
                local idx = (kn == "semicolon") and 1 or 2
                if ctx:select(pst + idx) then ctx:commit(); return kAccepted end
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
    local kn, sf, clean_key = _resolve_key(key_event, env)
    local ctx = env.engine.context
    local opts = env._opt 
    
    local sm_result = _smart_process(key_event, env, kn, sf, clean_key, opts)
    if sm_result == kAccepted then return kAccepted end

    local kc = key_event.keycode

    if key_event:release() then
        if ctx:has_menu() then
            if kc == 0xffe3 or kc == 0xffe4 then -- Ctrl
                 if ctx:select(1) then ctx:commit() end; return kAccepted
            elseif kc == 0xffe9 or kc == 0xffea then -- Alt
                 if ctx:select(2) then ctx:commit() end; return kAccepted
            end
        end
        return kNoop
    end

    if key_event:ctrl() or key_event:alt() then return kNoop end
    if kc < 32 or kc >= 127 then return kNoop end
    
    local key = CHAR_CACHE[kc] or clean_key

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
        local min_len = opts.danzi_mode and env._tu_min_dz or env._tu_min
        
        local prev = (input_len > 0) and string_sub(current_input, -1) or ""
        local first = (input_len > 0) and string_sub(current_input, 1, 1) or key
        
        local is_tu = env._tu_set[key]
        local is_ptu = env._tu_set[prev]
        local is_ftu = env._tu_set[first]

        if not (env._tu_cmd and is_ftu) then
             if not (opts.direct_symbols and input_len > 0 and string_byte(current_input, 1) == 59) then
                if is_ptu and not is_tu then _topup_exec(env)
                elseif not is_ptu and not is_tu and input_len >= min_len then _topup_exec(env)
                elseif input_len >= env._tu_max then _topup_exec(env) end
             end
        end
    end

    return kNoop
end

local function init(env)
    local config = env.engine.schema.config
    local ctx = env.engine.context
    
    if env._option_handler and ctx.option_update_notifier then
        pcall(function() ctx.option_update_notifier:disconnect(env._option_handler) end)
    end

    env._opt = {
        smarttwo = ctx:get_option("smarttwo"),
        direct_symbols = ctx:get_option("direct_symbols"),
        jisuanqi = ctx:get_option("jisuanqi"),
        auto_fallback = ctx:get_option("auto_fallback"),
        danzi_mode = ctx:get_option("danzi_mode"),
    }

    if ctx.option_update_notifier then
        local function on_option(context, name)
            if env._opt[name] ~= nil then env._opt[name] = context:get_option(name) end
        end
        env._option_handler = on_option
        ctx.option_update_notifier:connect(on_option)
    end

    env._ks = {}
    env._sw = nil
    env._dc = nil
    
    local ab = config:get_string("speller/alphabet") or "abcdefghijklmnopqrstuvwxyz"
    env._alpha = {}
    for i = 1, #ab do env._alpha[string_sub(ab,i,i)] = true end
    
    env._tu_set = _s2set(config:get_string("topup/topup_with") or "")
    env._tu_min = config:get_int("topup/min_length") or 4
    env._tu_min_dz = config:get_int("topup/min_length_danzi") or env._tu_min
    env._tu_max = config:get_int("topup/max_length") or 6
    env._tu_ac = config:get_bool("topup/auto_clear") or false
    env._tu_cmd = config:get_bool("topup/topup_command") or false
    env._tu_streaming = config:get_bool("translator/enable_sentence") or false
    env._tc = nil
    env._tc_pending = true
    collectgarbage("collect")
end

local function fini(env)
    local ctx = env.engine and env.engine.context
    if ctx and env._option_handler then
        pcall(function() ctx.option_update_notifier:disconnect(env._option_handler) end)
    end
    env._option_handler = nil
    env._opt = nil
    env._ks = nil
    env._alpha = nil
    env._tu_set = nil
end

return { init = init, func = processor, fini = fini }
