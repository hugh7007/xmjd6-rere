-- candidate_order_processor.lua
-- Hotkey runtime candidate promotion for candidate_order.txt.
-- Default: 0. If a non-first candidate is highlighted, promote it; otherwise promote the second candidate.

local core = require("xmjd6.candidate_order_core")

local kAccepted = 1
local kNoop = 2

local function get_store_file(env)
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        local file = env.engine.schema.config:get_string("candidate_order/store_file")
        if file and file ~= "" then return file end
    end
    return core.default_filename
end

local function get_hotkey(env)
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        local hotkey = env.engine.schema.config:get_string("candidate_order/hotkey")
        if hotkey and hotkey ~= "" then return hotkey end
    end
    return "0"
end

local function is_ctrl_j(key)
    if not key or key:release() then return false end
    if key:ctrl() and not key:alt() and not key:super() then
        local code = key.keycode or 0
        return code == string.byte("j") or code == string.byte("J")
    end
    local repr = key:repr() or ""
    return repr == "Control+j" or repr == "Control+J" or repr == "Ctrl+j" or repr == "Ctrl+J"
end

local function is_hotkey(key, hotkey)
    if not key or key:release() then return false end
    local repr = key:repr() or ""
    local code = key.keycode or 0

    -- Keep Ctrl+j as a desktop compatibility shortcut even when the unified hotkey is 0.
    if is_ctrl_j(key) then return true end

    if hotkey == "0" then
        return (not key:ctrl() and not key:alt() and not key:super())
            and (repr == "0" or code == string.byte("0"))
    end

    if repr == hotkey then return true end
    return false
end

local function selected_index(context)
    local comp = context and context.composition and context.composition:back()
    if not comp then return 0, nil end
    return comp.selected_index or 0, comp
end

local function get_candidate_at(comp, index)
    if not comp then return nil end
    local ok, cand = pcall(function() return comp:get_candidate_at(index) end)
    if ok then return cand end
    return nil
end

local function get_first_candidate(comp)
    return get_candidate_at(comp, 0)
end

local function prefix_fallback_records(input, store_file)
    local out = {}
    local ok, _, new_records = pcall(core.records_for_input, input, store_file)
    if not ok or type(new_records) ~= "table" then return out end

    for _, rec in ipairs(new_records) do
        if rec.displaced and rec.new_code
            and #input < #rec.new_code
            and input ~= rec.target_code
            and rec.new_code:sub(1, #input) == input then
            out[rec.displaced] = rec
        end
    end
    return out
end

local function prefix_fallback_record(cand, fallback_records)
    return cand and cand.type == "candidate_order"
        and fallback_records and fallback_records[cand.text] or nil
end

local function is_prefix_fallback_candidate(cand, fallback_records)
    return prefix_fallback_record(cand, fallback_records) ~= nil
end

local function get_non_prefix_candidate_at_or_after(comp, start_index, fallback_records)
    for index = start_index, start_index + 9 do
        local cand = get_candidate_at(comp, index)
        if not cand then return nil, nil end
        if not is_prefix_fallback_candidate(cand, fallback_records) then
            return cand, index
        end
    end
    return nil, nil
end

local function split_lookup_codes(s)
    local out = {}
    if type(s) ~= "string" then return out end
    for code in s:gmatch("[a-z]+") do
        out[#out + 1] = code
    end
    return out
end

local function choose_old_code(text, target_code, env)
    -- 调频是低频操作；ReverseLookup 只在按 0 时临时打开，用完即丢，
    -- 避免用户偶尔调一次词频后把反查库常驻在 Lua env 里。
    local dict_name = nil
    pcall(function() dict_name = env.engine.schema.config:get_string("translator/dictionary") end)
    dict_name = dict_name or "xmjd6.extended"
    local ok_reverse, reverse = pcall(ReverseLookup, dict_name)
    if not ok_reverse or not reverse then return target_code end

    local ok, lookup = pcall(function() return reverse:lookup(text) end)
    reverse = nil
    if not ok or not lookup then return target_code end
    local codes = split_lookup_codes(lookup)

    -- Prefer completion code under the current input, e.g. target bmms -> selected 边骂 bmmsa.
    for _, code in ipairs(codes) do
        if code:sub(1, #target_code) == target_code and #code > #target_code then
            return code
        end
    end
    -- Same-code reorder, e.g. both candidates are bmms.
    for _, code in ipairs(codes) do
        if code == target_code then return code end
    end
    -- Fallback: any code that begins with target, then first known code.
    for _, code in ipairs(codes) do
        if code:sub(1, #target_code) == target_code then return code end
    end
    return codes[1] or target_code
end

local function processor(key, env)
    if not core.is_enabled(env) then return kNoop end
    if not is_hotkey(key, get_hotkey(env)) then return kNoop end

    local engine = env and env.engine
    local context = engine and engine.context
    if not context or not context:has_menu() then return kNoop end

    local target_code = context.input or ""
    if not target_code:match("^[a-z]+$") then return kNoop end

    local store_file = get_store_file(env)
    local idx, comp = selected_index(context)
    local selected = context:get_selected_candidate()
    local visual_first = get_first_candidate(comp)
    local fallback_records = prefix_fallback_records(target_code, store_file)
    local first, first_index = get_non_prefix_candidate_at_or_after(comp, 0, fallback_records)
    if not first or not first.text or first.text == "" then return kNoop end

    -- When typing a generated fallback code only partially, candidate_order may
    -- yield a synthetic completion such as 缘由(~i). It is only a hint for the
    -- displaced word, not the real "first candidate". If the user highlights
    -- the real exact candidate below it (源由 at ytyda in the regression case),
    -- just clear the stale menu instead of appending an extra wrong rule.
    if visual_first and is_prefix_fallback_candidate(visual_first, fallback_records)
        and selected and selected.text == first.text then
        context:clear()
        return kAccepted
    end

    -- But if the user explicitly highlights that synthetic completion itself,
    -- promote it to the current prefix and move the real first candidate to the
    -- old fallback code. Example:
    --   before: ytyda = 源由, 缘由 completes to ytydai
    --   after : ytyda = 缘由, 源由 moves to ytydai
    local selected_prefix_rec = prefix_fallback_record(selected, fallback_records)
    if selected_prefix_rec then
        local ok = core.promote_prefix_fallback(
            selected_prefix_rec,
            target_code,
            first.text,
            core.store_path(store_file)
        )
        if ok then context:clear() end
        return kAccepted
    end

    -- Mobile-friendly behavior: if the cursor is still on the first candidate,
    -- pressing 0 promotes the second candidate directly. If the user has moved
    -- the highlight, pressing 0 promotes the highlighted candidate.
    if idx == first_index or not selected or selected.text == first.text then
        selected = get_non_prefix_candidate_at_or_after(comp, first_index + 1, fallback_records)
    end
    if not selected or not selected.text or selected.text == "" then return kAccepted end
    if selected.text == first.text then return kAccepted end

    local promoted = selected.text
    local displaced = first.text
    local old_code = choose_old_code(promoted, target_code, env)
    collectgarbage("collect")

    local ok = core.append_order({
        promoted = promoted,
        old_code = old_code,
        displaced = displaced,
        target_code = target_code,
    }, core.store_path(store_file))

    if ok then
        -- Clear stale menu. Type the same code again to see the adjusted order immediately.
        context:clear()
        return kAccepted
    end

    return kAccepted
end

return { func = processor }
