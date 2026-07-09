-- 天行键 自造词按键处理器
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-02

local core = require("zzc.xmjd6_zzc_core")

local kAccepted = 1
local kNoop = 2

local state = { active = false, stage = "off", items = {}, mode = "make", target_code = "", origin_input = "", display_word = "", replaced_word = "", command_candidates = {}, shorten_idx = 1 }
local current_action_candidate
local first_candidate
local reset
local refresh_context
local command_candidate_snapshot
local collect_lookup_input

local zzc_props = {
    "_xmjd6_zzc_stage",
    "_xmjd6_zzc_word",
    "_xmjd6_zzc_items",
    "_xmjd6_zzc_len",
    "_xmjd6_zzc_pending",
    "_xmjd6_zzc_mode",
    "_xmjd6_zzc_target",
    "_xmjd6_zzc_origin",
    "_xmjd6_zzc_display",
    "_xmjd6_zzc_replaced",
    "_xmjd6_zzc_cmd_candidates",
    "_xmjd6_zzc_shorten_idx",
}

local probe_props = {
    "_xmjd6_zzc_stage",
    "_xmjd6_zzc_word",
    "_xmjd6_zzc_items",
    "_xmjd6_zzc_len",
    "_xmjd6_zzc_pending",
    "_xmjd6_zzc_mode",
    "_xmjd6_zzc_target",
    "_xmjd6_zzc_origin",
    "_xmjd6_zzc_display",
    "_xmjd6_zzc_replaced",
}


local function reset_state_fields()
    state.active = false
    state.stage = "off"
    state.items = {}
    state.mode = "make"
    state.target_code = ""
    state.origin_input = ""
    state.display_word = ""
    state.replaced_word = ""
    state.command_candidates = {}
    state.shorten_idx = 1
    core.set_state_items(state.items)
    core.set_current_stage(state.stage)
end

local function clear_props(ctx, props)
    if not (ctx and ctx.set_property) then return end
    for _, name in ipairs(props or zzc_props) do
        ctx:set_property(name, "")
    end
end

local function snapshot_props(ctx, props)
    local out = {}
    if not (ctx and ctx.get_property) then return out end
    for _, name in ipairs(props or zzc_props) do
        out[name] = ctx:get_property(name) or ""
    end
    return out
end

local function restore_props(ctx, snapshot, props)
    if not (ctx and ctx.set_property) then return end
    for _, name in ipairs(props or zzc_props) do
        ctx:set_property(name, snapshot and snapshot[name] or "")
    end
end

local length_keys = {
    ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6,
    ["三"] = 3, ["四"] = 4, ["五"] = 5, ["六"] = 6,
    ["KP_3"] = 3, ["KP_4"] = 4, ["KP_5"] = 5, ["KP_6"] = 6,
    ["kp_3"] = 3, ["kp_4"] = 4, ["kp_5"] = 5, ["kp_6"] = 6,
}

local index_keys = {
    ["1"] = 1, ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5,
    ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9,
    ["KP_1"] = 1, ["KP_2"] = 2, ["KP_3"] = 3, ["KP_4"] = 4, ["KP_5"] = 5,
    ["KP_6"] = 6, ["KP_7"] = 7, ["KP_8"] = 8, ["KP_9"] = 9,
    ["kp_1"] = 1, ["kp_2"] = 2, ["kp_3"] = 3, ["kp_4"] = 4, ["kp_5"] = 5,
    ["kp_6"] = 6, ["kp_7"] = 7, ["kp_8"] = 8, ["kp_9"] = 9,
}

local collect_select_keys = {
    [";"] = 2, ["semicolon"] = 2, ["Semicolon"] = 2,
    ["'"] = 3, ["apostrophe"] = 3, ["Apostrophe"] = 3,
    ["Tab"] = 2, ["tab"] = 2,
}

local chinese_index_words = {
    ["一"] = 1, ["二"] = 2, ["三"] = 3, ["四"] = 4, ["五"] = 5,
    ["六"] = 6, ["七"] = 7, ["八"] = 8, ["九"] = 9,
}

local trigger_keys = {
    ["\\"] = true,
    ["backslash"] = true,
    ["Backslash"] = true,
    ["bar"] = true,
    ["|"] = true,
}

local function normalize_trigger_key(key)
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

local function event_char(key_event)
    local code = key_event.keycode
    if code and code >= 0x20 and code < 0x7f then return string.char(code) end
    return nil
end

local function resolve_collect_modifier_select_key(key_event, key)
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
    if (ctrl or is_ctrl_key) and not alt and is_ctrl_key then
        return 2
    end
    if (alt or is_alt_key) and not ctrl and is_alt_key then
        return 3
    end
    return nil
end

local function is_trigger(key, ch)
    if trigger_keys[ch or ""] or trigger_keys[key or ""] then return true end
    if type(key) == "string" then
        local clean = normalize_trigger_key(key)
        return trigger_keys[clean] or trigger_keys[clean:lower()]
    end
    return false
end

local function is_code_char(ch)
    return type(ch) == "string" and ch:match("^[A-Za-z;']$") ~= nil
end

local key_code_char_map = {
    semicolon = ";",
    apostrophe = "'",
}

local function resolve_code_char(key, ch)
    if is_code_char(ch) then return ch end
    if type(key) ~= "string" then return nil end
    local clean = key:match("^[Ss]hift%+(.*)") or key
    if is_code_char(clean) then return clean end
    local lower = clean:lower()
    local mapped = key_code_char_map[lower]
    if mapped and is_code_char(mapped) then return mapped end
    return nil
end

local function strip_zzc_prefix(input)
    input = input or ""
    if input:sub(1, 1) == "\\" then return input:sub(2) end
    return input
end

local function code_backslash_target(input)
    input = tostring(input or "")
    if #input > 1 and input:sub(-1) == "\\" then
        return input:sub(1, -2)
    end
    return nil
end

local function is_space(key)
    if type(key) ~= "string" then return false end
    local clean = key:match("^[Ss]hift%+(.*)") or key
    return clean:lower() == "space"
end

local function is_less_key(key, ch)
    local fullwidth_less = string.char(0xEF, 0xBC, 0x9C)
    local left_angle = string.char(0xE3, 0x80, 0x8A)
    if ch == "<" or ch == "," or ch == fullwidth_less or ch == left_angle
        or key == "less" or key == "Less" or key == "comma" or key == fullwidth_less or key == left_angle then return true end
    if type(key) == "string" then
        local clean = key:match("^[Ss]hift%+(.*)") or key
        return clean == "<" or clean == fullwidth_less or clean == left_angle
            or clean == "comma" or clean:lower() == "less" or key:match("^[Ss]hift%+comma$")
    end
    return false
end

local function is_minus_key(key, ch)
    local fullwidth_minus = string.char(0xEF, 0xBC, 0x8D)
    local minus_sign = string.char(0xE2, 0x88, 0x92)
    if ch == "-" or ch == fullwidth_minus or ch == minus_sign then return true end
    if type(key) ~= "string" then return false end
    local clean = key:match("^[Ss]hift%+(.*)") or key
    local lower = clean:lower()
    return lower == "minus" or lower == "hyphen" or clean == "-" or clean == fullwidth_minus or clean == minus_sign
end

local function is_unshifted_equal_key(key, ch, shifted)
    if shifted then return false end
    if ch == "=" then return true end
    if type(key) ~= "string" then return false end
    local clean = key:match("^[Ss]hift%+(.*)") or key
    local lower = clean:lower()
    return lower == "equal" or clean == "="
end

local function is_plus_key(key, ch, shifted, keycode)
    local fullwidth_plus = string.char(0xEF, 0xBC, 0x8B)
    if ch == "+" or ch == fullwidth_plus then return true end
    if type(key) ~= "string" then return false end
    local clean = key:match("^[Ss]hift%+(.*)") or key
    local lower = clean:lower()
    if lower == "equal" or clean == "=" then return true end
    if key:match("^[Ss]hift%+") and (lower == "equal" or clean == "=") then return true end
    if shifted and (lower == "equal" or clean == "=" or keycode == 61 or keycode == 0xBB or keycode == 43) then return true end
    return lower == "plus"
        or lower == "kp_add"
        or lower == "kp_plus"
        or lower == "numpad_add"
        or lower == "numpad_plus"
        or lower == "add"
        or keycode == 61
        or keycode == 0xBB
        or keycode == 43
        or clean == "+"
        or clean == fullwidth_plus
end

local function is_fullwidth_bang_text(text)
    return type(text) == "string"
        and #text == 3
        and text:byte(1) == 0xEF
        and text:byte(2) == 0xBC
        and text:byte(3) == 0x81
end

local function is_bang_key(key, ch, shifted, keycode)
    local fullwidth_bang = string.char(0xEF, 0xBC, 0x81)
    if ch == fullwidth_bang or key == fullwidth_bang then return true end
    if ch == "!" or is_fullwidth_bang_text(ch) then return true end
    if shifted and (keycode == 49 or keycode == 0x31) then return true end
    if type(key) ~= "string" then return false end
    local shifted_key = key:match("^[Ss]hift%+") ~= nil
    local clean = key:match("^[Ss]hift%+(.*)") or key
    local lower = clean:lower()
    return clean == "!" or clean == "！" or lower == "exclam" or (shifted_key and (clean == "1" or lower == "exclam"))
end

local function is_backspace(key)
    return type(key) == "string" and key:lower() == "backspace"
end

local function is_enter_key(key)
    if type(key) ~= "string" then return false end
    local lower = key:lower()
    return lower == "return" or lower == "enter"
end

local function is_null_key(key)
    return key == "0x0000"
end

local function is_ascii_mode(ctx)
    return ctx and ctx.get_option and ctx:get_option("ascii_mode")
end

local symbol_keys = {
    ["\\"] = true,
    ["|"] = true,
    ["backslash"] = true,
    ["bar"] = true,
    ["Backslash"] = true,
    ["Escape"] = true,
    ["escape"] = true,
    ["Backspace"] = true,
    ["backspace"] = true,
    ["less"] = true,
    ["Less"] = true,
    ["<"] = true,
    ["minus"] = true,
    ["Minus"] = true,
    ["hyphen"] = true,
    ["Hyphen"] = true,
    ["-"] = true,
    ["space"] = true,
    ["Space"] = true,
    [" "] = true,
}

local function is_zzc_reserved_key(key, ch)
    if symbol_keys[key or ""] or symbol_keys[ch or ""] then return true end
    if type(key) ~= "string" then return false end
    local clean = key:match("^[Ss]hift%+(.*)") or key
    return symbol_keys[clean] or symbol_keys[clean:lower()]
end

reset = function(ctx)
    reset_state_fields()
    clear_props(ctx)
    if ctx then ctx:clear() end
end

local function clear_state_only(ctx)
    reset_state_fields()
    clear_props(ctx)
end

local function sync_state(ctx)
    core.set_state_items(state.items)
    core.set_current_stage(state.stage)
    if ctx and ctx.set_property then
        ctx:set_property("_xmjd6_zzc_stage", state.stage ~= "off" and state.stage or "")
        local current_word = core.buffer_word() or ""
        if current_word == "" and not (state.stage == "collect" and state.mode == "replace") then
            current_word = state.display_word or ""
        end
        ctx:set_property("_xmjd6_zzc_word", current_word)
        ctx:set_property("_xmjd6_zzc_items", core.serialize_items(state.items))
        ctx:set_property("_xmjd6_zzc_mode", state.mode or "make")
        ctx:set_property("_xmjd6_zzc_target", state.target_code or "")
        ctx:set_property("_xmjd6_zzc_origin", state.origin_input or "")
        ctx:set_property("_xmjd6_zzc_display", state.display_word or "")
        ctx:set_property("_xmjd6_zzc_replaced", state.replaced_word or "")
        ctx:set_property("_xmjd6_zzc_cmd_candidates", table.concat(state.command_candidates or {}, "\n"))
        ctx:set_property("_xmjd6_zzc_shorten_idx", tostring(state.shorten_idx or 1))
    end
end

refresh_context = function(ctx)
    if not ctx then return end
    pcall(function()
        if ctx.refresh_non_confirmed_composition then
            ctx:refresh_non_confirmed_composition()
        end
    end)
end

local function composition_empty(ctx)
    return not ctx or not ctx.composition or ctx.composition:empty()
end

local function has_visible_menu(ctx)
    return ctx and ctx.has_menu and ctx:has_menu()
end

local function code_page_key_should_fallthrough(ctx, input, key, ch, shifted)
    if not has_visible_menu(ctx) then return false end
    local code = tostring(input or "")
    if code:sub(1, 1) == "\\" then code = code:sub(2) end
    if code:sub(-1) == "\\" then return false end
    if code == "" or not code:match("^[A-Za-z;']+$") then return false end
    return is_minus_key(key, ch) or is_unshifted_equal_key(key, ch, shifted)
end

local function set_pending_trigger(ctx, enabled)
    if not (ctx and ctx.set_property) then return end
    ctx:set_property("_xmjd6_zzc_pending", enabled and "1" or "")
end

local function pending_trigger(ctx)
    return ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_pending") == "1"
end




local function fallback_to_trigger(ctx)
    clear_state_only(ctx)
    set_pending_trigger(ctx, true)
    if ctx then
        ctx:clear()
        ctx.input = "\\"
    end
    refresh_context(ctx)
end

local function restore_state_from_context(ctx)
    if not (ctx and ctx.get_property) then return false end
    local prop_stage = ctx:get_property("_xmjd6_zzc_stage") or ""
    local prop_word = ctx:get_property("_xmjd6_zzc_word") or ""
    local prop_items = ctx:get_property("_xmjd6_zzc_items") or ""
    local prop_mode = ctx:get_property("_xmjd6_zzc_mode") or ""
    local prop_target = ctx:get_property("_xmjd6_zzc_target") or ""
    local prop_origin = ctx:get_property("_xmjd6_zzc_origin") or ""
    local prop_display = ctx:get_property("_xmjd6_zzc_display") or ""
    local prop_replaced = ctx:get_property("_xmjd6_zzc_replaced") or ""
    local prop_cmd_candidates = ctx:get_property("_xmjd6_zzc_cmd_candidates") or ""
    local prop_shorten_idx = tonumber(ctx:get_property("_xmjd6_zzc_shorten_idx") or "") or 1
    if prop_stage == "" and prop_word == "" and prop_items == "" then return false end
    local replace_placeholder = prop_stage == "collect"
        and prop_mode == "replace"
        and prop_target ~= ""
        and prop_items == ""
        and prop_word ~= ""
        and prop_word == prop_display
    local items = core.deserialize_items(prop_items)
    if (not items or #items == 0) and prop_word ~= "" and not replace_placeholder then
        items = core.items_from_text(prop_word) or {}
    end
    state.active = true
    state.stage = prop_stage ~= "" and prop_stage or "collect"
    state.items = items or {}
    state.mode = prop_mode ~= "" and prop_mode or "make"
    state.target_code = prop_target or ""
    state.origin_input = prop_origin or ""
    state.display_word = prop_display ~= "" and prop_display or prop_word or ""
    state.replaced_word = prop_replaced or ""
    state.shorten_idx = prop_shorten_idx
    state.command_candidates = {}
    for line in prop_cmd_candidates:gmatch("[^\n]+") do
        state.command_candidates[#state.command_candidates + 1] = line
    end
    core.set_state_items(state.items)
    core.set_current_stage(state.stage)
    return true
end

local function sync_state_from_context_if_needed(ctx)
    if not (ctx and ctx.get_property) then return false end
    local prop_stage = ctx:get_property("_xmjd6_zzc_stage") or ""
    if prop_stage == "" then return false end
    if (not state.active) or state.stage ~= prop_stage then
        return restore_state_from_context(ctx)
    end
    return false
end

local function context_has_active_state(ctx)
    if not (ctx and ctx.get_property) then return false end
    return (ctx:get_property("_xmjd6_zzc_stage") or "") ~= ""
        or (ctx:get_property("_xmjd6_zzc_word") or "") ~= ""
        or (ctx:get_property("_xmjd6_zzc_items") or "") ~= ""
end

local function show_selected_code_notice(ctx, word, code)
    clear_state_only(ctx)
    if not (ctx and ctx.set_property) then return end
    ctx:set_property("_xmjd6_zzc_stage", "resolve_notice")
    ctx:set_property("_xmjd6_zzc_word", word or "")
    ctx:set_property("_xmjd6_zzc_target", code or "")
    ctx:set_property("_xmjd6_zzc_display", word or "")
end

local function recover_collect_items(ctx)
    if state.items and #state.items > 0 then return true end
    if core.state_items and #core.state_items > 0 then
        state.items = core.state_items
        return true
    end
    if ctx and ctx.get_property then
        local prop_items = ctx:get_property("_xmjd6_zzc_items") or ""
        local items = core.deserialize_items(prop_items)
        if items and #items > 0 then
            state.items = items
            core.set_state_items(state.items)
            return true
        end
        local prop_stage = ctx:get_property("_xmjd6_zzc_stage") or ""
        local prop_mode = ctx:get_property("_xmjd6_zzc_mode") or ""
        local prop_target = ctx:get_property("_xmjd6_zzc_target") or ""
        local prop_display = ctx:get_property("_xmjd6_zzc_display") or ""
        local prop_word = ctx:get_property("_xmjd6_zzc_word") or ""
        if prop_stage == "collect"
            and prop_mode == "replace"
            and prop_target ~= ""
            and prop_word ~= ""
            and prop_word == prop_display then
            return false
        end
        items = core.items_from_text(prop_word)
        if items and #items > 0 then
            state.items = items
            core.set_state_items(state.items)
            return true
        end
    end
    return false
end

local function menu_candidate_at(menu, index)
    local ok, cand = pcall(function() return menu:get_candidate_at(index) end)
    if not ok then return nil end
    return cand
end

first_candidate = function(ctx)
    if not ctx or not ctx.composition or ctx.composition:empty() then return nil end
    local seg = ctx.composition:back()
    local menu = seg and seg.menu
    if not menu then return nil end
    return menu_candidate_at(menu, 0)
end

local function selected_candidate(ctx)
    if not ctx or not ctx.has_menu or not ctx:has_menu() then return nil end
    local ok, cand = pcall(function() return ctx:get_selected_candidate() end)
    return ok and cand or nil
end

local candidate_type = core.candidate_type
local is_real_candidate = core.is_real_candidate

local function first_real_candidate(ctx)
    if not ctx or not ctx.composition or ctx.composition:empty() then return nil end
    local seg = ctx.composition:back()
    local menu = seg and seg.menu
    if not menu then return nil end
    for i = 0, 9 do
        local cand = menu_candidate_at(menu, i)
        if not cand then break end
        if is_real_candidate(cand) then
            return cand
        end
    end
    return nil
end

current_action_candidate = function(ctx)
    local cand = selected_candidate(ctx)
    if is_real_candidate(cand) then return cand end
    return first_real_candidate(ctx)
end

local function probe_first_candidate(ctx, code)
    if not ctx or not code or code == "" then return nil end
    local cover = core.cover_for_probe and core.cover_for_probe(code, { ignore_order = true }) or nil
    if cover and cover.rows and cover.rows[1] and cover.rows[1].word then
        return cover.rows[1].word
    end
    local old_input = ctx.input or ""
    local old_props = snapshot_props(ctx, probe_props)
    local old_core_stage = core.current_stage and core.current_stage() or "off"
    local text = nil
    local ok = pcall(function()
        if core.set_current_stage then core.set_current_stage("off") end
        clear_props(ctx, probe_props)
        ctx.input = code
        refresh_context(ctx)
        if ctx.composition and not ctx.composition:empty() then
            local seg = ctx.composition:back()
            local menu = seg and seg.menu
            if menu then
                for i = 0, 9 do
                    local cand = menu_candidate_at(menu, i)
                    if not cand then break end
                    if is_real_candidate(cand)
                        and (not cover or not cover.hide_words or not cover.hide_words[cand.text]) then
                        text = cand.text
                        break
                    end
                end
            end
        end
    end)
    pcall(function()
        ctx:clear()
        ctx.input = old_input
        if core.set_current_stage then core.set_current_stage(old_core_stage) end
        restore_props(ctx, old_props, probe_props)
        refresh_context(ctx)
    end)
    return text
end

local function length_from_candidate_text(text)
    return length_keys[text or ""]
end

local function append_text(text, code_hint)
    local appended, err = core.append_candidate_text(text, code_hint)
    if not appended then return nil, err end
    state.items = core.state_items or state.items
    return appended
end

local function append_text_raw(text)
    local appended, err = core.append_candidate_text(text, nil)
    if not appended then return nil, err end
    state.items = core.state_items or state.items
    return appended
end

local function is_cjk_text(text)
    return text and text:match("[\228-\233][\128-\191][\128-\191]") ~= nil
end

local function commit_current_candidate(ctx, env)
    if not ctx then return false end
    if ctx.commit and ctx:is_composing() then
        ctx:commit()
        return true
    end
    local cand = current_action_candidate(ctx) or first_candidate(ctx)
    if not is_real_candidate(cand) then return false end
    local text = cand.text
    if not text or text == "" or not is_cjk_text(text) then return false end
    if env and env.engine then
        env.engine:commit_text(text)
        ctx:clear()
        return true
    end
    return false
end

local function capture_current_candidate(ctx, next_input, opts)
    if not ctx then return nil end
    opts = opts or {}
    local code_hint = collect_lookup_input(ctx.input)
    local cand = current_action_candidate(ctx) or first_candidate(ctx)
    if not is_real_candidate(cand) then return nil end
    local text = cand.text
    if not text or text == "" or not is_cjk_text(text) then return nil end
    local appended
    if state.mode == "make" and (not state.target_code or state.target_code == "") then
        appended = append_text_raw(text)
    else
        appended = append_text(text, code_hint)
    end
    if not appended then return nil end
    state.display_word = core.buffer_word() or state.display_word
    if opts.preserve_input then
        sync_state(ctx)
        return appended
    end
    ctx:clear()
    ctx.input = next_input ~= nil and next_input or "\\"
    sync_state(ctx)
    refresh_context(ctx)
    return appended
end

local function capture_candidate_at(ctx, idx)
    if not ctx or not idx or idx < 1 or idx > 9 then return nil end
    if not ctx.composition or ctx.composition:empty() then return nil end
    local seg = ctx.composition:back()
    local menu = seg and seg.menu
    if not menu then return nil end
    local cand = menu_candidate_at(menu, idx - 1)
    if not is_real_candidate(cand) then return nil end
    local text = cand.text
    if not text or text == "" or not is_cjk_text(text) then return nil end
    local code_hint = collect_lookup_input(ctx.input)
    local appended
    if state.mode == "make" and (not state.target_code or state.target_code == "") then
        appended = append_text_raw(text)
    else
        appended = append_text(text, code_hint)
    end
    if not appended then return nil end
    state.display_word = core.buffer_word() or state.display_word
    ctx:clear()
    ctx.input = "\\"
    sync_state(ctx)
    refresh_context(ctx)
    return appended
end

local function pending_input_code(ctx)
    local input = ctx and ctx.input or ""
    if input == "" or input == "\\" then return "" end
    return collect_lookup_input(input)
end

local function collect_display_prefix()
    if state.stage ~= "collect" then return "\\" end
    if state.mode == "append" and (state.target_code or "") ~= "" then
        return (state.target_code or "") .. "\\+"
    end
    if state.mode == "replace" and (state.target_code or "") ~= "" then
        return (state.target_code or "") .. "\\"
    end
    return "\\"
end

collect_lookup_input = function(input)
    input = tostring(input or "")
    local prefix = collect_display_prefix()
    if prefix ~= "" and input:sub(1, #prefix) == prefix then
        return input:sub(#prefix + 1)
    end
    if input:sub(1, 1) == "\\" then
        return strip_zzc_prefix(input)
    end
    return input
end

local function update_collect_input_shape(ctx)
    if not (ctx and state.stage == "collect") then return false end
    if not ((state.mode == "append" or state.mode == "replace") and (state.target_code or "") ~= "") then return false end
    local lookup = collect_lookup_input(ctx.input)
    if lookup == "" or lookup == "\\" then return false end
    local shaped = lookup
    if not probe_first_candidate(ctx, lookup) then
        shaped = collect_display_prefix() .. lookup
    end
    if ctx.input ~= shaped then
        ctx.input = shaped
        refresh_context(ctx)
        return true
    end
    return false
end

local function push_collect_code_char(ctx, ch)
    if not (ctx and ch and ch ~= "" and state.stage == "collect") then return false end
    if not ((state.mode == "append" or state.mode == "replace") and (state.target_code or "") ~= "") then return false end
    local lookup = collect_lookup_input(ctx.input)
    if #lookup >= 6 then
        ctx.input = collect_display_prefix()
        sync_state(ctx)
        refresh_context(ctx)
        return true
    end
    lookup = lookup .. ch
    if probe_first_candidate(ctx, lookup) then
        ctx.input = lookup
    else
        ctx.input = collect_display_prefix() .. lookup
    end
    sync_state(ctx)
    refresh_context(ctx)
    return true
end

local function prepare_collect_lookup_for_capture(ctx)
    if not (ctx and state.stage == "collect") then return false end
    if not ((state.mode == "append" or state.mode == "replace") and (state.target_code or "") ~= "") then return false end
    local input = ctx.input or ""
    local lookup = collect_lookup_input(input)
    if lookup == "" or lookup == "\\" or input == lookup then return false end
    ctx.input = lookup
    refresh_context(ctx)
    return true
end

local function current_direct_code(ctx)
    local code = pending_input_code(ctx)
    if code ~= "" and code:match("^[A-Za-z;']+$") then return code end
    return nil
end

local function command_trigger_code(input)
    return tostring(input or "" ):match("^(.*)\\%-$")
end

local function split_command_input(input)
    local prefix, directive = tostring(input or ""):match("^(.-)\\(.*)$")
    if prefix == nil then return nil, nil end
    return prefix, directive or ""
end

local function begin_command_wait(ctx, mode, target_code, display_word, command_candidates, do_refresh)
    state.active = true
    state.stage = "command_wait"
    state.items = {}
    state.mode = mode
    state.target_code = target_code or ""
    state.origin_input = (target_code and target_code ~= "") and (target_code .. "\\") or "\\"
    state.display_word = display_word or ""
    state.replaced_word = ""
    state.command_candidates = command_candidates or {}
    sync_state(ctx)
    if do_refresh then refresh_context(ctx) end
    return kAccepted
end

local function begin_undo_command(ctx)
    return begin_command_wait(ctx, "undo", "", "-", {}, true)
end

local function begin_restore_wait(ctx, target_code)
    local candidates = {}
    for _, row in ipairs(core.restore_rows_for_input(target_code) or {}) do
        candidates[#candidates + 1] = row.word or ""
    end
    return begin_command_wait(ctx, "restore", target_code, "", candidates, true)
end

local function switch_command_wait(ctx, mode, display_word)
    state.stage = "command_wait"
    state.mode = mode
    state.origin_input = state.origin_input ~= "" and state.origin_input or ((state.target_code or "") ~= "" and ((state.target_code or "") .. "\\") or "\\")
    state.display_word = display_word or ""
    sync_state(ctx)
    refresh_context(ctx)
    return kAccepted
end

local function restore_plain_input(ctx, input)
    clear_state_only(ctx)
    set_pending_trigger(ctx, false)
    if ctx then
        ctx:clear()
        ctx.input = input or ""
    end
    refresh_context(ctx)
    return kAccepted
end

local function handle_command_wait_backspace(ctx)
    local display = state.display_word or ""
    if state.mode == "promote" then
        if display ~= "" then
            display = display:sub(1, -2)
            if display ~= "" then
                state.display_word = display
                sync_state(ctx)
                refresh_context(ctx)
                return kAccepted
            end
        end
        return restore_plain_input(ctx, (state.target_code or "") .. "\\")
    end
    if state.mode == "delete" then
        if display ~= "" then
            state.display_word = display:sub(1, -2)
            sync_state(ctx)
            refresh_context(ctx)
            return kAccepted
        end
        return restore_plain_input(ctx, (state.target_code or "") .. "\\")
    end
    if state.mode == "undo" then
        if display ~= "" then
            state.display_word = display:sub(1, -2)
            sync_state(ctx)
            refresh_context(ctx)
            return kAccepted
        end
        return restore_plain_input(ctx, "\\")
    end
    if display ~= "" then
        state.display_word = display:sub(1, -2)
        sync_state(ctx)
        refresh_context(ctx)
        return kAccepted
    end
    reset(ctx)
    return kAccepted
end

local function restore_code_backslash_input(ctx)
    local origin = state.origin_input or ""
    if origin ~= "" then return restore_plain_input(ctx, origin) end
    local target = state.target_code or ""
    return restore_plain_input(ctx, target ~= "" and (target .. "\\") or "\\")
end

local function restore_code_without_backslash(ctx)
    local origin = state.origin_input or ""
    local code = origin:gsub("\\$", "")
    if code == "" then code = state.target_code or "" end
    return restore_plain_input(ctx, code)
end

local function handle_shorten_wait_backspace(ctx)
    local idx = tonumber(state.shorten_idx or 1) or 1
    if idx > 1 then
        state.shorten_idx = 1
        set_default_shorten_display()
        sync_state(ctx)
        refresh_context(ctx)
        return kAccepted
    end
    return restore_code_backslash_input(ctx)
end

local function handle_collect_backspace(ctx)
    if state.stage == "collect" then
        recover_collect_items(ctx)
        if (not state.display_word or state.display_word == "") and ctx and ctx.get_property then
            state.display_word = core.buffer_word() or (ctx:get_property("_xmjd6_zzc_word") or "")
        end
    end
    if state.stage == "collect"
        and (state.mode == "append" or state.mode == "replace")
        and ctx.input and ctx.input ~= "" and ctx.input ~= "\\" then
        local lookup = collect_lookup_input(ctx.input)
        if #lookup > 1 then
            lookup = lookup:sub(1, -2)
            ctx.input = lookup
            sync_state(ctx)
            refresh_context(ctx)
            return kAccepted
        end
        ctx.input = "\\"
        sync_state(ctx)
        refresh_context(ctx)
        return kAccepted
    end
    if state.stage == "collect" and ctx.input and #ctx.input == 1 and ctx.input ~= "\\" then
        ctx.input = "\\"
        sync_state(ctx)
        refresh_context(ctx)
        return kAccepted
    end
    if state.stage == "collect"
        and state.mode == "make"
        and (state.items == nil or #state.items == 0)
        and ctx.input == "\\" then
        reset(ctx)
        return kAccepted
    end
    if state.stage == "collect" and ctx.input and ctx.input ~= "" and ctx.input ~= "\\" then
        return kNoop
    end
    if state.stage == "collect"
        and (state.mode == "append" or state.mode == "replace")
        and ctx.input == "\\"
        and #state.items == 0 then
        if state.mode == "append" then
            return restore_code_backslash_input(ctx)
        end
        return restore_code_without_backslash(ctx)
    end
    if #state.items > 0 then
        table.remove(state.items)
        core.set_state_items(state.items)
        state.display_word = core.buffer_word() or ""
        if #state.items > 0 then
            ctx.input = "\\"
            sync_state(ctx)
            refresh_context(ctx)
        else
            state.stage = "collect"
            state.active = true
            ctx.input = "\\"
            sync_state(ctx)
            refresh_context(ctx)
        end
        return kAccepted
    end
    if ctx.input and ctx.input ~= "" then return kNoop end
    reset(ctx)
    return kAccepted
end

local function set_default_shorten_display()
    if state.command_candidates and state.command_candidates[1] then
        state.display_word = state.command_candidates[1]
    end
end

local function begin_shorten_wait(ctx, target_code)
    state.active = true
    state.stage = "shorten_wait"
    state.items = {}
    state.mode = "shorten"
    state.target_code = target_code
    state.origin_input = (target_code and target_code ~= "") and (target_code .. "\\") or "\\"
    state.display_word = ""
    state.replaced_word = ""
    state.command_candidates = command_candidate_snapshot(ctx, target_code)
    state.shorten_idx = 1
    set_default_shorten_display()
    sync_state(ctx)
    refresh_context(ctx)
    return kAccepted
end

local function switch_shorten_wait(ctx)
    state.stage = "shorten_wait"
    state.mode = "shorten"
    state.shorten_idx = 1
    state.display_word = (state.command_candidates and state.command_candidates[1]) or state.display_word or ""
    sync_state(ctx)
    refresh_context(ctx)
    return kAccepted
end

command_candidate_snapshot = function(ctx, code, opts)
    opts = opts or {}
    local out = {}
    local seen = {}
    local cover = core.zzc_cover_for_input and core.zzc_cover_for_input(code or "")
    local append_out = {}
    local append_seen = {}
    local function add_cover_rows(rows)
        for _, row in ipairs(rows or {}) do
            local word = row and row.word
            if word and word ~= "" and not seen[word] then
                out[#out + 1] = word
                seen[word] = true
            end
        end
    end
    local function add_append_rows(rows)
        for _, row in ipairs(rows or {}) do
            local word = row and row.word
            if word and word ~= "" and not seen[word] and not append_seen[word] then
                append_out[#append_out + 1] = word
                append_seen[word] = true
            end
        end
    end
    local function flush_append_rows()
        for _, word in ipairs(append_out) do
            if not seen[word] then
                out[#out + 1] = word
                seen[word] = true
            end
        end
        append_out = {}
        append_seen = {}
    end
    local function collect_from_menu(menu)
        if not menu then return end
        for i = 0, 8 do
            local cand = menu_candidate_at(menu, i)
            if not cand then break end
            local cand_type = candidate_type(cand)
            local zzc_candidate = cand_type == "zzc_saved" or cand_type == "zzc_cover" or cand_type == "zzc_append"
            if cand_type == "zzc_append" then
                if is_real_candidate(cand) and cand.text and cand.text ~= "" and not seen[cand.text] and not append_seen[cand.text] then
                    append_out[#append_out + 1] = cand.text
                    append_seen[cand.text] = true
                end
            elseif is_real_candidate(cand)
                and (cand.preedit == code or zzc_candidate)
                and not seen[cand.text]
                and (zzc_candidate
                    or not cover
                    or ((not cover.keep_words or not cover.keep_words[cand.text])
                        and (not cover.hide_words or not cover.hide_words[cand.text]))) then
                out[#out + 1] = cand.text
                seen[cand.text] = true
            end
        end
    end
    if ctx and ctx.composition and not ctx.composition:empty() then
        local seg = ctx.composition:back()
        collect_from_menu(seg and seg.menu)
    end
    if cover and cover.rows then add_cover_rows(cover.rows) end
    if cover and cover.append_rows then add_append_rows(cover.append_rows) end
    if not ctx or not code or code == "" then
        flush_append_rows()
        return out
    end
    local old_input = ctx.input or ""
    local old_props = snapshot_props(ctx)
    local old_core_stage = core.current_stage and core.current_stage() or "off"
    pcall(function()
        if core.set_current_stage then core.set_current_stage("off") end
        clear_props(ctx)
        ctx.input = code
        refresh_context(ctx)
        if ctx.composition and not ctx.composition:empty() then
            local seg = ctx.composition:back()
            collect_from_menu(seg and seg.menu)
        end
    end)
    if cover and cover.rows then add_cover_rows(cover.rows) end
    if cover and cover.append_rows then add_append_rows(cover.append_rows) end
    flush_append_rows()
    pcall(function()
        ctx:clear()
        ctx.input = old_input
        if core.set_current_stage then core.set_current_stage(old_core_stage) end
        restore_props(ctx, old_props)
        refresh_context(ctx)
    end)
    return out
end

local function promote_candidate_at(ctx, target_code, idx)
    if not idx or idx < 1 or idx > 9 then return false end
    local snapshot = state.command_candidates
    if not snapshot or not snapshot[1] then
        snapshot = command_candidate_snapshot(ctx, target_code)
    end
    if not (snapshot and snapshot[idx]) then
        snapshot = command_candidate_snapshot(ctx, target_code, { force_probe = true })
    end
    local word = snapshot[idx]
    if not word and snapshot and #snapshot == 1 then
        word = snapshot[1]
    end
    if word and target_code and target_code ~= "" then
        local reordered = { word }
        for i, item in ipairs(snapshot) do
            if i ~= idx then reordered[#reordered + 1] = item end
        end
        local ok, err = core.reorder_words_at_code(reordered, target_code)
    else
    end
    if ctx then ctx:clear() end
    reset(ctx)
    return true
end

local function shorten_candidate_at(ctx, source_code, idx)
    if not source_code or #source_code <= 1 then
        reset(ctx)
        return false
    end
    idx = idx or 1
    local snapshot = state.command_candidates
    if not snapshot or not snapshot[1] then
        snapshot = command_candidate_snapshot(ctx, source_code)
    end
    local word = snapshot[idx]
    local target_code = source_code:sub(1, -2)
    if word and target_code and target_code ~= "" then
        pcall(core.move_word_to_code, word, source_code, target_code, function(code)
            return probe_first_candidate(ctx, code)
        end, nil)
    end
    if ctx then ctx:clear() end
    reset(ctx)
    return true
end

local function startswith(text, prefix)
    return type(text) == "string" and type(prefix) == "string" and text:sub(1, #prefix) == prefix
end

local function resolve_length_key(key, ch)
    return length_keys[ch or ""] or length_keys[key or ""]
end

local function resolve_index_key(key, ch)
    return index_keys[ch or ""] or index_keys[key or ""]
end

local function resolve_collect_select_key(key, ch)
    return resolve_index_key(key, ch) or collect_select_keys[ch or ""] or collect_select_keys[key or ""]
end

local function waiting_length_confirm(ctx)
    if state.stage ~= "collect" or state.mode == "replace" then return false end
    recover_collect_items(ctx)
    return state.items and #state.items >= 2
end

local function ready_for_length(ctx)
    if state.stage ~= "collect" or state.mode == "replace" then return false end
    recover_collect_items(ctx)
    return state.items and #state.items >= 2
end

local function invalid_length_digit(idx, len)
    return idx and idx >= 1 and idx <= 9 and not len
end

local function selected_length_candidate(ctx, idx)
    if not ctx or not idx or idx < 1 or idx > 9 then return nil, nil end
    if not ctx.composition or ctx.composition:empty() then return nil, nil end
    local seg = ctx.composition:back()
    local menu = seg and seg.menu
    if not menu then return nil, nil end
    local cand = menu_candidate_at(menu, idx - 1)
    if not is_real_candidate(cand) then return nil, nil end
    local len = length_from_candidate_text(cand.text)
    if not len then return nil, cand.text end
    return len, cand.text
end

local function default_length_for_items(items)
    local n = #(items or {})
    if n == 2 then return 4 end
    if n == 3 then return 3 end
    if n >= 4 then return 4 end
    return nil
end

local function commit_command_deletes(ctx)
    local digits = state.display_word or ""
    if digits == "" then digits = "1" end
    local code = state.target_code or ""
    local snapshot = state.command_candidates
    for d in digits:gmatch("%d") do
        local idx = tonumber(d)
        if idx and idx >= 1 and idx <= 9 then
            if not (snapshot and snapshot[idx]) and code ~= "" then
                snapshot = command_candidate_snapshot(ctx, code, { force_probe = true })
            end
            local word = snapshot and snapshot[idx]
            if word and code ~= "" then
                local ok, err = core.delete_word_at_code(word, code)
            end
        end
    end
    reset(ctx)
    return kAccepted
end

local function commit_command_promote(ctx)
    local idx = tonumber(state.display_word or "")
    local code = state.target_code or ""
    if idx and idx >= 1 and idx <= 9 then
        promote_candidate_at(ctx, code, idx)
        return kAccepted
    end
    reset(ctx)
    return kAccepted
end

local function commit_command_restore(ctx)
    local idx = tonumber(state.display_word or "") or 1
    local word = state.command_candidates and state.command_candidates[idx]
    if word and word ~= "" then
        core.restore_word_at_code(word, state.target_code or "")
    end
    reset(ctx)
    return kAccepted
end

local function commit_code_choice(ctx, env, idx)
    local choice = state.command_candidates and state.command_candidates[idx]
    if not choice then
        return kAccepted
    end
    local word, code = choice:match("^([^\t]+)\t([^\t%s]+)")
    if not word or not code then
        return kAccepted
    end
    local items = state.items or {}
    if #items == 0 then
        items = core.items_from_text(word) or core.raw_items_from_text(word)
    end
    local len = tonumber((ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_len")) or "")
    if len then
        local choices = core.code_choices_for_text(word, len, 9)
        for _, resolved in ipairs(choices or {}) do
            if resolved.code == code then
                items = resolved.items or items
                break
            end
        end
    end
    local saved_code = core.save_word_at_code(items, code, nil, function(probe_code)
        return probe_first_candidate(ctx, probe_code)
    end)
    if not saved_code then
        state.stage = "collect"
        sync_state(ctx)
        return kAccepted
    end
    if ctx then ctx:clear() end
    show_selected_code_notice(ctx, word, code)
    if env and env.engine then env.engine:commit_text(word) end
    return kAccepted
end

local function selected_code_choice_index(ctx)
    local cand = selected_candidate(ctx)
    if candidate_type(cand) ~= "zzc_code_choice" then return 1 end
    local selected_code = cand.comment or ""
    for i, choice in ipairs(state.command_candidates or {}) do
        local _, code = choice:match("^([^\t]+)\t([^\t%s]+)")
        if code and code == selected_code then return i end
    end
    return 1
end

local function finalize_current(ctx, env, opts)
    opts = opts or {}
    if #state.items < 1 then
        reset(ctx)
        return kAccepted
    end
    local word = core.buffer_word()
    local saved_code, err
    if state.mode == "append" and state.target_code ~= "" then
        local saved_word_or_err
        saved_code, saved_word_or_err = core.append_word_at_code(state.items, state.target_code)
        if saved_code then
            err = nil
        else
            err = saved_word_or_err
        end
    elseif state.mode == "replace" and state.target_code ~= "" then
        local promote_idx = chinese_index_words[word or ""]
        if promote_idx then
            promote_candidate_at(ctx, state.target_code, promote_idx)
            return kAccepted
        end
        local replaced_word = state.replaced_word
        if (not replaced_word or replaced_word == "") and state.target_code ~= "" then
            replaced_word = probe_first_candidate(ctx, state.target_code)
        end
        saved_code, err = core.enqueue_replace(state.items, state.target_code, replaced_word, function(code)
            return probe_first_candidate(ctx, code)
        end)
    else
        local len = opts.len or default_length_for_items(state.items)
        if not len then return kAccepted end
        if #state.items < 2 then
            sync_state(ctx)
            return kAccepted
        end
        local direct_code = opts.direct_code or current_direct_code(ctx)
        if direct_code and #direct_code == len then
            saved_code, err = core.save_word_at_code(state.items, direct_code, nil, function(code)
                return probe_first_candidate(ctx, code)
            end)
        else
            saved_code, err = core.enqueue_pending(state.items, len, function(code)
                return probe_first_candidate(ctx, code)
            end)
        end
        if not saved_code and err == "missing_parts" then
            local choices, choice_err = core.code_choices_for_text(word, len, 9)
            if choices and choices[1] then
                if #choices == 1 then
                    local choice = choices[1]
                    saved_code, err = core.save_word_at_code(choice.items or state.items, choice.code, nil, function(code)
                        return probe_first_candidate(ctx, code)
                    end)
                end
            end
            if not saved_code and choices and choices[1] then
                state.stage = "resolve_code"
                state.mode = "make"
                state.target_code = ""
                state.display_word = word
                state.command_candidates = {}
                for _, choice in ipairs(choices) do
                    state.command_candidates[#state.command_candidates + 1] = choice.word .. "\t" .. choice.code
                end
                sync_state(ctx)
                refresh_context(ctx)
                return kAccepted
            end
        end
    end
    if not saved_code then
        state.stage = "collect"
        sync_state(ctx)
        return kAccepted
    end
    reset(ctx)
    if env and env.engine and word and word ~= "" then
        env.engine:commit_text(word)
    end
    return kAccepted
end

local function finalize_with_length(ctx, len, env)
    if not len then return kAccepted end
    if ctx and ctx.set_property then ctx:set_property("_xmjd6_zzc_len", tostring(len)) end
    local direct_code = current_direct_code(ctx)
    if (ctx.input or "") ~= "" and (ctx.input or "") ~= "\\" then
        capture_current_candidate(ctx)
    end
    return finalize_current(ctx, env, { len = len, direct_code = direct_code })
end

local function handoff_length_to_filter(ctx, len, ch)
    if not ctx or not len then return kAccepted end
    if ctx.set_property then ctx:set_property("_xmjd6_zzc_len", tostring(len)) end
    local suffix = ch and ch ~= "" and ch or tostring(len)
    local word = core.buffer_word() or state.display_word or ""
    ctx.input = "\\" .. word .. suffix
    sync_state(ctx)
    refresh_context(ctx)
    return kAccepted
end

local function push_code_char(ctx, ch)
    if not ctx or not ch or ch == "" then return end
    local pushed = false
    if type(ctx.push_input) == "function" then
        local ok = pcall(function()
            ctx:push_input(ch)
        end)
        pushed = ok and true or false
    end
    if not pushed then
        ctx.input = (ctx.input or "") .. ch
    end
end

local function activate_collect(ctx)
    state.active = true
    state.stage = "collect"
    state.items = {}
    state.mode = "make"
    state.target_code = ""
    state.display_word = ""
    state.replaced_word = ""
    if ctx then ctx:clear() end
    sync_state(ctx)
end

local function begin_replace_collect(ctx, target_code)
    local cand = current_action_candidate(ctx) or first_candidate(ctx)
    local command_candidates = command_candidate_snapshot(ctx, target_code)
    local replaced_word = command_candidates[1] or (cand and cand.text) or ""
    state.active = true
    state.stage = "collect"
    state.items = {}
    state.mode = "replace"
    state.target_code = target_code or ""
    state.origin_input = (target_code and target_code ~= "") and (target_code .. "\\") or "\\"
    state.display_word = replaced_word ~= "" and replaced_word or (target_code or "")
    state.replaced_word = replaced_word
    state.command_candidates = command_candidates
    if ctx then ctx:clear() end
    sync_state(ctx)
end

local function begin_append_collect(ctx, target_code)
    state.active = true
    state.stage = "collect"
    state.items = {}
    state.mode = "append"
    state.target_code = target_code or ""
    state.origin_input = (target_code and target_code ~= "") and (target_code .. "\\") or "\\"
    state.display_word = ""
    state.replaced_word = ""
    state.command_candidates = {}
    if ctx then
        ctx:clear()
        ctx.input = "\\"
    end
    sync_state(ctx)
    refresh_context(ctx)
end

local function handle_target_command_key(ctx, target_code, key, ch, shifted, keycode, opts)
    opts = opts or {}
    local idx = resolve_index_key(key, ch)
    if idx and idx >= 1 and idx <= 9 then
        return begin_command_wait(ctx, "promote", target_code, tostring(idx), command_candidate_snapshot(ctx, target_code), true)
    end
    if is_less_key(key, ch) then
        return begin_shorten_wait(ctx, target_code)
    end
    if is_minus_key(key, ch) then
        return begin_command_wait(ctx, "delete", target_code, "", command_candidate_snapshot(ctx, target_code), true)
    end
    if is_bang_key(key, ch, shifted, keycode) then
        return begin_command_wait(ctx, "undo", target_code, "!", command_candidate_snapshot(ctx, target_code), true)
    end
    if is_plus_key(key, ch, shifted, keycode) then
        if opts.plus_restores then
            return begin_restore_wait(ctx, target_code)
        end
        begin_append_collect(ctx, target_code)
        return kAccepted
    end
    return nil
end

local function handle_replace_wait(ctx, current_input, key, ch, shifted, keycode)
    local replace_prefix = (state.target_code or "") .. "\\"
    local idx = resolve_index_key(key, ch)
    if idx and idx >= 1 and idx <= 9 then
        return switch_command_wait(ctx, "promote", tostring(idx))
    end
    if is_less_key(key, ch) then
        return switch_shorten_wait(ctx)
    end
    if is_minus_key(key, ch) then
        return switch_command_wait(ctx, "delete", "")
    end
    if is_plus_key(key, ch, shifted, keycode) then
        if state.mode == "append" and state.target_code ~= "" and #state.items == 0 then
            return begin_restore_wait(ctx, state.target_code)
        end
        begin_append_collect(ctx, state.target_code)
        return kAccepted
    end
    if startswith(current_input, replace_prefix) and #current_input > #replace_prefix then
        state.stage = "collect"
        state.display_word = core.buffer_word() or state.display_word
        ctx:clear()
        ctx.input = "\\" .. current_input:sub(#replace_prefix + 1)
        sync_state(ctx)
        return kAccepted
    end
    if is_backspace(key) then
        return restore_code_backslash_input(ctx)
    end
    if is_trigger(key, ch) then
        reset(ctx)
        return kAccepted
    end
    if is_code_char(ch) then
        state.stage = "collect"
        state.display_word = core.buffer_word() or state.display_word
        ctx:clear()
        ctx.input = "\\"
        sync_state(ctx)
        return kNoop
    end
    return kAccepted
end

local function handle_command_wait(ctx, key, ch, shifted, keycode)
    if is_backspace(key) or key == "Escape" or key == "escape" then
        if is_backspace(key) then
            return handle_command_wait_backspace(ctx)
        end
        reset(ctx)
        return kAccepted
    end
    if is_trigger(key, ch) then
        if state.mode == "delete" then
            return commit_command_deletes(ctx)
        end
        if state.mode == "promote" then
            return commit_command_promote(ctx)
        end
        if state.mode == "restore" then
            return commit_command_restore(ctx)
        end
        if state.mode == "undo" and state.display_word == "-" then
            core.undo_last_tx()
            reset(ctx)
            return kAccepted
        end
        if state.mode == "undo" and (state.display_word == "!!!" or state.display_word == "！！！") then
            core.undo_all_pending()
            reset(ctx)
            return kAccepted
        end
        reset(ctx)
        return kAccepted
    end
    if state.mode == "undo" and is_bang_key(key, ch, shifted, keycode) then
        state.display_word = (state.display_word or "") .. "!"
        sync_state(ctx)
        refresh_context(ctx)
        return kAccepted
    end
    if state.mode == "undo" and is_minus_key(key, ch) then
        state.display_word = (state.display_word or "") .. "-"
        sync_state(ctx)
        refresh_context(ctx)
        return kAccepted
    end
    if state.mode == "delete" and is_minus_key(key, ch) then
        return begin_command_wait(ctx, "undo", state.target_code or "", "-", {}, true)
    end
    local idx = resolve_index_key(key, ch)
    if idx and idx >= 1 and idx <= 9 then
        state.display_word = (state.display_word or "") .. tostring(idx)
        sync_state(ctx)
        refresh_context(ctx)
        return kAccepted
    end
    if state.mode == "restore" and (ch == "r" or ch == "R" or key == "r" or key == "R") and (not state.display_word or state.display_word == "") then
        state.display_word = "1"
        sync_state(ctx)
        refresh_context(ctx)
        return kAccepted
    end
    return kAccepted
end

local function processor(key_event, env)
    local key = key_event:repr()
    if not core.allowed(env) then return kNoop end
    local ctx = env.engine.context
    if state.active and not context_has_active_state(ctx) then
        clear_state_only(ctx)
    end
    if ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_finalize") == "1" then
        clear_state_only(ctx)
        if ctx.set_property then ctx:set_property("_xmjd6_zzc_finalize", "") end
    end
    local current_input = ctx and ctx.input or ""
    sync_state_from_context_if_needed(ctx)
    local ch = event_char(key_event)
    local shifted = key_event:shift()
    local keycode = key_event.keycode
    if state.stage == "collect" and has_visible_menu(ctx) then
        if key_event:release() then
            local modifier_idx = resolve_collect_modifier_select_key(key_event, key)
            if modifier_idx then
                capture_candidate_at(ctx, modifier_idx)
                return kAccepted
            end
        end
    end
    if key_event:release() then
        if is_trigger(key, ch) then
            if state.stage == "command_wait" then
                return handle_command_wait(ctx, key, ch, shifted, keycode)
            end
            if state.stage == "shorten_wait" then
                local idx = tonumber(state.shorten_idx or 1) or 1
                shorten_candidate_at(ctx, state.target_code, idx)
                return kAccepted
            end
            if state.stage == "collect"
                and (state.mode == "replace" or state.mode == "append") then
                if (ctx.input or "") ~= "" and (ctx.input or "") ~= "\\" then
                    capture_current_candidate(ctx)
                end
                recover_collect_items(ctx)
                if #state.items > 0 then
                    return finalize_current(ctx, env, { direct_code = state.target_code })
                end
                reset(ctx)
                return kAccepted
            end
            if state.stage == "collect" and state.mode == "make" then
                recover_collect_items(ctx)
                if #state.items > 0 then
                    return finalize_current(ctx, env)
                end
            end
        end
        return kNoop
    end
    if key_event:ctrl() or key_event:alt() then return kNoop end
    local code_char = resolve_code_char(key, ch)
    local direct_len = resolve_length_key(key, ch)

    if current_input == "" and code_char and composition_empty(ctx) then
        local prop_stage = ctx and ctx.get_property and (ctx:get_property("_xmjd6_zzc_stage") or "") or ""
        if state.active or prop_stage ~= "" then
            clear_state_only(ctx)
            return kNoop
        end
    end

    if is_ascii_mode(ctx) then return kNoop end
    if state.active and is_null_key(key) then
        reset(ctx)
        return kAccepted
    end
    if not state.active then
        restore_state_from_context(ctx)
    end
    if state.stage == "resolve_code" then
        if is_backspace(key) or key == "Escape" or key == "escape" then
            reset(ctx)
            return kAccepted
        end
        if is_space(key) then
            return commit_code_choice(ctx, env, selected_code_choice_index(ctx))
        end
        local idx = resolve_index_key(key, ch)
        if idx and idx >= 1 and idx <= 9 then
            return commit_code_choice(ctx, env, idx)
        end
        return kAccepted
    end
    if state.stage == "command_wait" then
        return handle_command_wait(ctx, key, ch, shifted, keycode)
    end
    if state.stage == "shorten_wait" then
        if key == "Escape" or key == "escape" then
            reset(ctx)
            return kAccepted
        end
        if is_backspace(key) then
            return handle_shorten_wait_backspace(ctx)
        end
        if is_trigger(key, ch) or key == "backslash" or key == "Backslash" or ch == "\\" or is_less_key(key, ch) then
            local idx = tonumber(state.shorten_idx or 1) or 1
            shorten_candidate_at(ctx, state.target_code, idx)
            return kAccepted
        end
        local idx = resolve_index_key(key, ch)
        if idx and idx >= 1 and idx <= 9 then
            state.shorten_idx = idx
            local word = state.command_candidates and state.command_candidates[idx]
            if word and word ~= "" then state.display_word = word end
            sync_state(ctx)
            refresh_context(ctx)
            return kAccepted
        end
        return kAccepted
    end

    if not state.active then
        if is_backspace(key) and current_input ~= "\\" then
            return kNoop
        end
        local command_prefix, command_directive = split_command_input(current_input)
        if command_prefix ~= nil and (command_directive == "!!!" or command_directive == "！！！") then
            core.undo_all_pending()
            reset(ctx)
            return kAccepted
        end
        if command_prefix ~= nil and command_directive == "--" then
            return begin_command_wait(ctx, "undo", command_prefix or "", "-", {}, true)
        end
        if current_input == "\\-" and is_minus_key(key, ch) then
            return begin_command_wait(ctx, "undo", "", "-", {}, true)
        end
        local command_code = command_trigger_code(current_input)
        if command_code then
            local code = command_code
            return begin_command_wait(ctx, code == "" and "undo" or "delete", code, "", command_candidate_snapshot(ctx, code), false)
        end
        if current_input == "\\" then
            if is_enter_key(key) then
                set_pending_trigger(ctx, false)
                if ctx then ctx:clear() end
                if env and env.engine then env.engine:commit_text("\\") end
                return kAccepted
            end
            if is_backspace(key) or key == "Escape" or key == "escape" then
                set_pending_trigger(ctx, false)
                if ctx then ctx:clear() end
                return kAccepted
            end
            if is_less_key(key, ch) then
                set_pending_trigger(ctx, false)
                return kNoop
            end
            if is_minus_key(key, ch) then
                set_pending_trigger(ctx, false)
                return begin_command_wait(ctx, "undo", "", "", {}, true)
            end
            if is_bang_key(key, ch, shifted, keycode) then
                set_pending_trigger(ctx, false)
                return begin_command_wait(ctx, "undo", "", "!", {}, true)
            end
            local idx = resolve_index_key(key, ch)
            if idx then
                set_pending_trigger(ctx, false)
                return kNoop
            end
            if code_char then
                set_pending_trigger(ctx, false)
                activate_collect(ctx)
                return kNoop
            end
            set_pending_trigger(ctx, false)
            return kNoop
        end
        local target_code = code_backslash_target(current_input)
        if target_code ~= nil then
            if code_page_key_should_fallthrough(ctx, current_input, key, ch, shifted) then
                return kNoop
            end
            if is_backspace(key) or key == "Escape" or key == "escape" then
                return kNoop
            end
            local command_result = handle_target_command_key(ctx, target_code, key, ch, shifted, keycode)
            if command_result then return command_result end
            if code_char then
                begin_replace_collect(ctx, target_code)
                return kNoop
            end
            return kNoop
        end
        if is_trigger(key, ch) and (ctx.input or "") == "" then
            set_pending_trigger(ctx, true)
            if ctx then
                ctx:clear()
                ctx.input = "\\"
                refresh_context(ctx)
            end
            return kAccepted
        end
        if current_input == "\\" and code_char then
            set_pending_trigger(ctx, false)
            activate_collect(ctx)
            return kNoop
        end
        if pending_trigger(ctx) then
            if code_page_key_should_fallthrough(ctx, current_input, key, ch, shifted) then
                set_pending_trigger(ctx, false)
                return kNoop
            end
            if is_less_key(key, ch) then
                set_pending_trigger(ctx, false)
                return kNoop
            end
            local idx = resolve_index_key(key, ch)
            if idx or is_minus_key(key, ch) then
                set_pending_trigger(ctx, false)
                if ctx then ctx:clear() end
                return kAccepted
            end
            if startswith(current_input, "\\") and #current_input > 1 then
                set_pending_trigger(ctx, false)
                state.active = true
                state.stage = "collect"
                state.items = {}
                state.mode = "make"
                state.target_code = ""
                state.display_word = ""
                state.replaced_word = ""
                sync_state(ctx)
                ctx.input = current_input:sub(2)
                return kAccepted
            end
            if code_char then
                set_pending_trigger(ctx, false)
                activate_collect(ctx)
                return kNoop
            end
            if not is_trigger(key, ch) and not is_backspace(key) then
                set_pending_trigger(ctx, false)
            end
        end
        if is_trigger(key, ch) and (ctx.input or "") ~= "" then
            return kNoop
        end
        if core.current_stage() ~= "off" and (direct_len or is_space(key) or is_backspace(key) or key == "Escape" or key == "escape") then
            state.active = true
            state.stage = core.current_stage()
            state.items = core.state_items or state.items
        else
            return kNoop
        end
    end

    if key == "Escape" or key == "escape" then
        reset(ctx)
        return kAccepted
    end

    if state.stage == "replace_wait" then
        return handle_replace_wait(ctx, current_input, key, ch, shifted, keycode)
    end

    if state.stage == "collect"
        and state.mode == "append"
        and state.target_code ~= ""
        and (ctx.input or "") == "\\"
        and is_plus_key(key, ch, shifted, keycode) then
        return begin_restore_wait(ctx, state.target_code)
    end

    if state.stage == "collect"
        and state.mode == "replace"
        and state.target_code ~= ""
        and (ctx.input or "") == "\\" then
        local command_result = handle_target_command_key(ctx, state.target_code, key, ch, shifted, keycode)
        if command_result then return command_result end
    end

    if state.stage == "collect" and code_char and (ctx.input or "") == "\\" then
        ctx:clear()
        sync_state(ctx)
        return kNoop
    end

    if state.stage == "collect" and (ctx.input or "") == "\\" and ch and ch ~= "" and not is_trigger(key, ch) then
        local idx = resolve_index_key(key, ch)
        if waiting_length_confirm(ctx) and idx and idx >= 1 and idx <= 9 then
            if direct_len then
                return handoff_length_to_filter(ctx, direct_len, ch)
            end
            if invalid_length_digit(idx, direct_len) then
                reset(ctx)
                return kAccepted
            end
            return kAccepted
        end
        if is_zzc_reserved_key(key, ch) then
            return kAccepted
        end
        ctx:clear()
        return kNoop
    end

    if state.stage == "collect"
        and (state.mode == "replace" or state.mode == "append")
        and is_trigger(key, ch)
        and (ctx.input or "") ~= ""
        and (ctx.input or "") ~= "\\" then
        capture_current_candidate(ctx)
        if #state.items > 0 then
            return finalize_current(ctx, env, { direct_code = state.target_code })
        end
        reset(ctx)
        return kAccepted
    end

    if state.stage == "collect" and code_char and (ctx.input or ""):sub(1, 1) == "\\" and #(ctx.input or "") > 1 then
        ctx.input = strip_zzc_prefix(ctx.input)
        sync_state(ctx)
        return kNoop
    end

    if state.stage == "collect"
        and not ((state.mode == "replace" or state.mode == "append") and (state.target_code or "") ~= "")
        and code_char
        and has_visible_menu(ctx) then
        return kNoop
    end

    if state.stage == "collect" and code_page_key_should_fallthrough(ctx, ctx and ctx.input or "", key, ch, shifted) then
        return kNoop
    end

    if is_backspace(key) then
        return handle_collect_backspace(ctx)
    end

    if state.stage == "collect" then
        local length_idx = resolve_index_key(key, ch)
        if waiting_length_confirm(ctx) and length_idx and length_idx >= 1 and length_idx <= 9 then
            if direct_len then
                return handoff_length_to_filter(ctx, direct_len, ch)
            end
            if invalid_length_digit(length_idx, direct_len) then
                reset(ctx)
                return kAccepted
            end
            return kAccepted
        end
        local idx = has_visible_menu(ctx) and resolve_collect_select_key(key, ch) or nil
        if idx and idx >= 1 and idx <= 9 then
            if ready_for_length(ctx) then
                local cand_len, cand_text = selected_length_candidate(ctx, idx)
                if cand_len then
                    if ctx then ctx:clear() end
                    return handoff_length_to_filter(ctx, cand_len, cand_text)
                end
            end
            capture_candidate_at(ctx, idx)
            return kAccepted
        end
    end

    if direct_len and state.mode ~= "replace" and waiting_length_confirm(ctx) then
        return handoff_length_to_filter(ctx, direct_len, ch)
    end

    if state.stage == "collect" then
        if is_trigger(key, ch) then
            if state.mode == "replace" or state.mode == "append" then
                if (ctx.input or "") ~= "" and (ctx.input or "") ~= "\\" then
                    capture_current_candidate(ctx)
                end
                if #state.items > 0 then
                    return finalize_current(ctx, env, { direct_code = state.target_code })
                end
            elseif state.mode == "make" and #state.items > 0 then
                return finalize_current(ctx, env)
            end
            reset(ctx)
            return kAccepted
        end
        if is_space(key) then
            if (ctx.input or "") == "" then return kNoop end
            prepare_collect_lookup_for_capture(ctx)
            local cand = current_action_candidate(ctx) or first_candidate(ctx)
            local cand_len = cand and length_from_candidate_text(cand.text)
            if cand_len and ready_for_length(ctx) then
                ctx:clear()
                return handoff_length_to_filter(ctx, cand_len, cand.text)
            end
            local text = capture_current_candidate(ctx)
            if not text then return kAccepted end
            return kAccepted
        end
        return kNoop
    end

    if is_zzc_reserved_key(key, ch) then
        return kAccepted
    end
    return kNoop
end

local function module_is_active(ctx)
    if state.active and (state.stage == "collect" or state.stage == "command_wait" or state.stage == "resolve_code" or state.stage == "shorten_wait") then return true end
    if ctx and ctx.get_property then
        return (ctx:get_property("_xmjd6_zzc_stage") or "") ~= ""
    end
    return false
end

local function module_capture_current_candidate(ctx, next_input)
    if not module_is_active(ctx) then return false end
    local text = capture_current_candidate(ctx, next_input)
    return text and true or false
end

local function init(env)
    if core.apply_reset_marker then
        local reset_ok, reset_result, reset_changed_or_err = pcall(core.apply_reset_marker)
        if reset_ok and reset_result then
            env._zzc_reset_changed = reset_changed_or_err == true
        elseif reset_ok then
            env._zzc_flush_ok = false
            env._zzc_flush_error = tostring(reset_changed_or_err or "")
            return
        else
            env._zzc_flush_ok = false
            env._zzc_flush_error = tostring(reset_result or "")
            return
        end
    end
    if not core.cleanup_appended_runtime_ops then return end
    local ok, result, changed_or_err = pcall(core.cleanup_appended_runtime_ops)
    if ok then
        env._zzc_flush_ok = result and true or false
        env._zzc_flush_changed = changed_or_err == true
        env._zzc_flush_error = result and nil or tostring(changed_or_err or "")
    else
        env._zzc_flush_ok = false
        env._zzc_flush_changed = false
        env._zzc_flush_error = tostring(result or "")
    end
end

local function fini(env)
    if not core.flush_runtime_ops then return end
    local ok, result, changed_or_err = pcall(core.flush_runtime_ops)
    if ok then
        env._zzc_flush_ok = result and true or false
        env._zzc_flush_changed = changed_or_err == true
        env._zzc_flush_error = result and nil or tostring(changed_or_err or "")
    else
        env._zzc_flush_ok = false
        env._zzc_flush_changed = false
        env._zzc_flush_error = tostring(result or "")
    end
end

return {
    init = init,
    func = processor,
    fini = fini,
    is_active = module_is_active,
    capture_current_candidate = module_capture_current_candidate,
}
