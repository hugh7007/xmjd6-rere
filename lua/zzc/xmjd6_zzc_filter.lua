-- 天行键 自造词显示过滤器
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-02

local core = require("zzc.xmjd6_zzc_core")
local processor = require("zzc.xmjd6_zzc_processor")
local length_inputs = require("zzc.xmjd6_zzc_keys").length_keys
local COLLECT_CANDIDATE_LIMIT = 30
local DEFAULT_ZZC_HINT_TEXT = "自造词ing"
local DEFAULT_ZZC_CANDIDATE_HINT_TEXT = "自造词"

local is_real_candidate = core.is_real_candidate

local function is_collect_candidate(cand)
    return cand
        and cand.text
        and cand.text ~= ""
        and cand.text:sub(1, 1) ~= "~"
end

local with_reminder

local function literal_length_input(ctx, input_text)
    if not (ctx and ctx.get_property and type(input_text) == "string") then return nil end
    if ctx:get_property("_xmjd6_zzc_stage") ~= "collect" or ctx:get_property("_xmjd6_zzc_mode") ~= "make" then return nil end
    local word = ctx:get_property("_xmjd6_zzc_word") or ""
    if word == "" then return nil end
    local suffix
    if utf8 and utf8.offset then
        local start = utf8.offset(input_text, -1)
        suffix = start and input_text:sub(start) or input_text
    else
        suffix = input_text:sub(-1)
    end
    local len = length_inputs[suffix]
    if not len or input_text ~= "\\" .. word .. suffix then return nil end
    return len
end

local function zzc_hint_text(env)
    if env and env._zzc_hint_text ~= nil then
        return env._zzc_hint_text
    end
    return DEFAULT_ZZC_HINT_TEXT
end

local function zzc_candidate_hint_text(env)
    if env and env._zzc_candidate_hint_text ~= nil then
        return env._zzc_candidate_hint_text
    end
    return DEFAULT_ZZC_CANDIDATE_HINT_TEXT
end

local function state_candidate(ctx, code, env)
    local prop_stage = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_stage") or ""
    local prop_word = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_word") or ""
    local prop_mode = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_mode") or ""
    local prop_display = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_display") or ""
    local prop_target = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_target") or ""
    local prop_items = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_items") or ""
    if core.current_stage() == "off" and prop_stage == "" and prop_word == "" then return nil end
    local word = core.buffer_word()
    local pending_code = ""
    local pending_display = ""
    if prop_stage == "collect" and code and code ~= "" and code ~= "\\" then
        local prefix = prop_mode == "append" and (prop_target .. "\\+") or (prop_target .. "\\")
        if prop_target ~= "" and code:sub(1, #prefix) == prefix then
            pending_code = code:sub(#prefix + 1)
            pending_display = pending_code
        else
            local payload = code:sub(1, 1) == "\\" and code:sub(2) or code
            if prop_mode == "make" and word and word ~= "" and payload:sub(1, #word) == word then
                pending_code = payload:sub(#word + 1)
            else
                pending_code = payload
            end
            pending_display = pending_code
        end
        if pending_code and not pending_code:match("^[A-Za-z;']+$") then
            pending_code = ""
        end
    end
    if (prop_mode == "delete" or prop_mode == "promote" or prop_mode == "restore") and prop_stage == "command_wait" and prop_target ~= "" then
        word = prop_target
    elseif prop_mode == "undo" and prop_stage == "command_wait" then
        word = prop_display ~= "" and prop_display or "-"
    elseif prop_mode == "shorten" and prop_display ~= "" and prop_stage == "shorten_wait" then
        word = prop_display
    elseif prop_stage == "resolve_notice" and prop_display ~= "" then
        word = prop_display
    elseif prop_mode == "append" and prop_target ~= "" and prop_stage == "collect" then
        word = prop_word
    elseif prop_mode == "replace" and prop_stage == "collect" and prop_target ~= "" then
        word = prop_word
    elseif prop_mode == "replace" and prop_display ~= "" and (prop_stage == "replace_wait" or prop_items == "") then
        word = prop_display
    elseif word == "" then
        word = prop_word
    end
    if (not word or word == "")
        and not (prop_mode == "append" and prop_target ~= "" and prop_stage == "collect")
        and not (prop_mode == "replace" and prop_target ~= "" and prop_stage == "collect") then return nil end
    local text
    if prop_mode == "delete" and prop_stage == "command_wait" and prop_target ~= "" then
        text = prop_target .. "\\-" .. (prop_display or "")
    elseif prop_mode == "restore" and prop_stage == "command_wait" and prop_target ~= "" then
        text = prop_target .. "\\++" .. (prop_display or "")
    elseif prop_mode == "promote" and prop_stage == "command_wait" and prop_target ~= "" then
        text = prop_target .. "\\" .. (prop_display or "")
    elseif prop_mode == "undo" and prop_stage == "command_wait" then
        local display = prop_display or ""
        local prefix = prop_target ~= "" and (prop_target .. "\\") or "\\"
        if display:match("^[!！]+$") then
            text = prefix .. display
        else
            text = prefix .. "-" .. display
        end
    elseif prop_mode == "shorten" and prop_display ~= "" and prop_stage == "shorten_wait" then
        text = word .. "\\<"
    elseif prop_stage == "resolve_notice" then
        text = word
    elseif prop_mode == "append" and prop_target ~= "" and prop_stage == "collect" then
        text = prop_target .. "\\+" .. (word or "") .. (pending_code or "")
    elseif prop_mode == "replace" and prop_stage == "collect" and prop_target ~= "" then
        text = prop_target .. "\\" .. (word or "") .. (pending_code or "")
    elseif prop_mode == "replace" and prop_display ~= "" and (prop_stage == "replace_wait" or prop_items == "") then
        text = word .. "\\"
    elseif prop_stage == "collect" and pending_display ~= "" then
        text = "\\" .. word .. pending_display
    else
        text = "\\" .. word
    end
    local end_pos = #code
    if end_pos < 1 then end_pos = 1 end
    local comment = zzc_hint_text(env)
    if prop_stage == "resolve_notice" and prop_target ~= "" then
        comment = "已选编码 " .. prop_target
    end
    local cand_text = text
    if prop_stage == "collect" and prop_mode == "replace" and prop_target ~= "" then
        cand_text = word ~= "" and word or pending_code
    elseif prop_stage == "collect" and word ~= "" and pending_code ~= "" then
        cand_text = word
    end
    local cand = Candidate("zzc_state", 0, end_pos, cand_text, comment)
    if prop_stage == "collect" then
        cand.preedit = text
    elseif prop_stage == "collect" and prop_mode == "replace" and prop_target ~= "" then
        if code ~= text then cand.preedit = text end
    elseif cand_text ~= text and code ~= text then
        cand.preedit = text
    end
    cand.quality = 10000
    return cand
end

local function collect_lookup_code(ctx, code)
    local prop_stage = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_stage") or ""
    local prop_mode = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_mode") or ""
    local prop_target = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_target") or ""
    if prop_stage == "collect"
        and (prop_mode == "replace" or prop_mode == "append")
        and prop_target ~= "" then
        local prefix = prop_mode == "append" and (prop_target .. "\\+") or (prop_target .. "\\")
        if tostring(code or ""):sub(1, #prefix) == prefix then
            return tostring(code or ""):sub(#prefix + 1)
        end
        if tostring(code or ""):sub(1, 1) == "\\" then
            return tostring(code or ""):sub(2)
        end
    end
    return code
end

local function collect_display_preedit(ctx, lookup_code)
    local prop_stage = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_stage") or ""
    local prop_mode = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_mode") or ""
    local prop_target = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_target") or ""
    local prop_word = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_word") or ""
    local word = core.buffer_word() or prop_word or ""
    if prop_stage ~= "collect" or prop_target == "" then return nil end
    if prop_mode == "append" then
        return prop_target .. "\\+" .. word .. tostring(lookup_code or "")
    end
    if prop_mode == "replace" then
        return prop_target .. "\\" .. word .. tostring(lookup_code or "")
    end
    return nil
end

local function collect_make_preedit(ctx, code)
    local prop_stage = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_stage") or ""
    local prop_mode = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_mode") or ""
    if prop_stage ~= "collect" or prop_mode ~= "make" then return nil end
    local word = core.buffer_word() or (ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_word") or "")
    if word == "" then return nil end
    local payload = tostring(code or "")
    if payload:sub(1, 1) == "\\" then payload = payload:sub(2) end
    if payload:sub(1, #word) == word then payload = payload:sub(#word + 1) end
    if payload == "" then return nil end
    if not payload:match("^[A-Za-z;']+$") and not payload:match("^[三四五六][A-Za-z;']+$") then return nil end
    return "\\" .. word .. payload
end

local function yield_restore_candidates(ctx, code)
    local prop_stage = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_stage") or ""
    local prop_mode = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_mode") or ""
    if prop_stage ~= "command_wait" or prop_mode ~= "restore" then return false end
    local rows_text = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_cmd_candidates") or ""
    local idx = 0
    local yielded = false
    for line in rows_text:gmatch("[^\n]+") do
        idx = idx + 1
        local cand = Candidate("zzc_restore", 0, #code, line, "恢复")
        cand.quality = 10070 - idx
        yield(with_reminder(cand))
        yielded = true
    end
    return yielded
end

local function yield_code_choice_candidates(ctx, code)
    local prop_stage = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_stage") or ""
    if prop_stage ~= "resolve_code" then return false end
    local rows_text = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_cmd_candidates") or ""
    local idx = 0
    local yielded = false
    local zero_width_space = string.char(0xE2, 0x80, 0x8B)
    local length_text = { [3] = "三", [4] = "四", [5] = "五", [6] = "六" }
    local len = tonumber(ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_len") or "")
    for line in rows_text:gmatch("[^\n]+") do
        local word, choice_code = line:match("^([^\t]+)\t([^\t%s]+)")
        if word and choice_code then
            idx = idx + 1
            local display_word = word
            if idx > 1 then
                display_word = word .. zero_width_space:rep(idx - 1)
            end
            local cand = Candidate("zzc_code_choice", 0, #code, display_word, choice_code)
            cand.preedit = "\\" .. word .. (length_text[len] or tostring(len or ""))
            cand.quality = 10080 - idx
            yield(cand)
            yielded = true
        end
    end
    return yielded
end

local function with_preedit(cand, preedit_text)
    if not cand or not preedit_text or preedit_text == "" then return cand end
    local ok, nc = pcall(Candidate, cand.type or "derived", cand.start, cand._end, cand.text or "", cand.comment or "")
    if not ok or not nc then
        cand.preedit = preedit_text
        cand._xmjd6_zzc_preedit_only = true
        return cand
    end
    nc.preedit = preedit_text
    nc.quality = cand.quality
    nc._xmjd6_zzc_preedit_only = true
    return nc
end

with_reminder = function(cand)
    if not cand or not core.take_reminder_comment then return cand end
    local comment = core.take_reminder_comment()
    if comment and comment ~= "" then
        cand.comment = comment
    end
    return cand
end

local function yield_zzc_cover_candidates(input_text, cover, preedit_text, env)
    cover = cover or core.zzc_cover_for_input(input_text)
    if not cover then return nil end
    local first = true
    local yielded = false
    if cover.rows then
        for _, row in ipairs(cover.rows) do
            local cand = Candidate("zzc_cover", 0, #input_text, row.word, zzc_candidate_hint_text(env))
            cand.quality = 10060
            if first then
                cand.preedit = preedit_text or cand.preedit
                first = false
            end
            yield(with_reminder(cand))
            yielded = true
        end
    end
    if not yielded and not (cover.append_rows and cover.append_rows[1]) then return nil end
    return cover
end

local function yield_append_candidates(input_text, cover, env)
    if not cover or not cover.append_rows then return false end
    local yielded = false
    for _, row in ipairs(cover.append_rows) do
        local cand = Candidate("zzc_append", 0, #input_text, row.word, zzc_candidate_hint_text(env))
        cand.quality = 8000
        yield(with_reminder(cand))
        yielded = true
    end
    return yielded
end

local function yield_input_candidates(input, skip_first, real_only, preedit_text)
    local skipped = false
    local first = true
    local yielded = false
    for cand in input:iter() do
        if not real_only or is_real_candidate(cand) then
            if skip_first and not skipped then
                skipped = true
            else
                if first then
                    yield(with_preedit(cand, preedit_text))
                    first = false
                else
                    yield(cand)
                end
                yielded = true
            end
        end
    end
    return yielded
end

local function yield_filtered_input_candidates(input, cover, preedit_text)
    local first = true
    local yielded = false
    for cand in input:iter() do
        if is_real_candidate(cand) then
            if not cover
                or not cand.text
                or (not cover.keep_words[cand.text] and not cover.hide_words[cand.text]) then
                if first then
                    yield(with_preedit(cand, preedit_text))
                    first = false
                else
                    yield(cand)
                end
                yielded = true
            end
        else
            yield(cand)
            yielded = true
        end
    end
    return yielded
end

local function filter(input, env)
    if not core.allowed(env) then
        yield_input_candidates(input, false)
        return
    end
    local ctx = env.engine.context
    local code = ctx and ctx.input or ""
    local prop_stage = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_stage") or ""
    local prop_mode = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_mode") or ""
    local literal_len = literal_length_input(ctx, code)
    if literal_len and processor.finalize_literal_length(ctx, env, literal_len) then
        code = ctx and ctx.input or ""
        prop_stage = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_stage") or ""
        prop_mode = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_mode") or ""
        if prop_stage ~= "resolve_code" then return end
    end
    local state_cand = state_candidate(ctx, code, env)
    local prop_target = ctx and ctx.get_property and ctx:get_property("_xmjd6_zzc_target") or ""
    local collect_with_code = prop_stage == "collect"
        and (prop_mode == "replace" or prop_mode == "append")
        and prop_target ~= ""
        and code ~= ""
        and code ~= "\\"
    local lookup_code = collect_with_code and collect_lookup_code(ctx, code) or code
    local collect_preedit = collect_with_code and collect_display_preedit(ctx, lookup_code)
        or collect_make_preedit(ctx, code)
        or (state_cand and (state_cand.preedit or state_cand.text))
        or nil
    if yield_code_choice_candidates(ctx, code) then
        return
    end
    if state_cand and code == "" then
        yield(with_reminder(state_cand))
        return
    end
    if code == "\\" and state_cand then
        yield(with_reminder(state_cand))
        return
    end
    if state_cand and prop_mode == "restore" and prop_stage == "command_wait" then
        yield(with_reminder(state_cand))
        yield_restore_candidates(ctx, code)
        return
    end
    if state_cand and (prop_mode == "delete" or prop_mode == "promote" or prop_mode == "undo") and prop_stage == "command_wait" then
        yield(with_reminder(state_cand))
        return
    end
    if state_cand and prop_mode == "shorten" and prop_stage == "shorten_wait" then
        yield(with_reminder(state_cand))
        return
    end
    if state_cand and prop_stage == "resolve_notice" then
        yield(with_reminder(state_cand))
        return
    end
    if state_cand and prop_mode == "replace" and prop_stage == "replace_wait" then
        yield(with_reminder(state_cand))
        return
    end
    if code ~= "" and (not state_cand or collect_with_code) then
        local cover = core.zzc_order_for_input and core.zzc_order_for_input(lookup_code) or core.zzc_cover_for_input(lookup_code)
        if cover and cover.has_order then
            local yielded = yield_zzc_cover_candidates(code, cover, collect_preedit, env) ~= nil
            yielded = yield_append_candidates(code, cover, env) or yielded
            yielded = yield_filtered_input_candidates(input, cover, collect_preedit) or yielded
            return
        end
        cover = yield_zzc_cover_candidates(code, cover, collect_preedit, env)
        if cover then
            local yielded = cover.rows and cover.rows[1] ~= nil
            if not yielded then
                yielded = yield_filtered_input_candidates(input, cover, collect_preedit) or yielded
            end
            yielded = yield_append_candidates(code, cover, env) or yielded
            if cover.rows and cover.rows[1] then
                yielded = yield_filtered_input_candidates(input, cover, collect_preedit) or yielded
            end
            return
        end
        cover = core.zzc_cover_for_input and core.zzc_cover_for_input(lookup_code) or nil
        if cover and cover.hide_words then
            local yielded = yield_filtered_input_candidates(input, cover, collect_preedit)
            return
        end
    end
    if collect_with_code and collect_lookup_code(ctx, code) ~= code then
        return
    end
    if code == "" then
        if state_cand then yield(with_reminder(state_cand)) end
        for cand in input:iter() do yield(cand) end
        return
    end
    local yielded = yield_input_candidates(input, false, false, collect_preedit)
end

local function init(env)
    if not env then return end
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    if config and config.get_string then
        env._zzc_hint_text = config:get_string("zzc/hint_text")
        env._zzc_candidate_hint_text = config:get_string("zzc/candidate_hint_text")
    end
    if env._zzc_hint_text == nil then
        env._zzc_hint_text = DEFAULT_ZZC_HINT_TEXT
    end
    if env._zzc_candidate_hint_text == nil then
        env._zzc_candidate_hint_text = DEFAULT_ZZC_CANDIDATE_HINT_TEXT
    end
end

return { init = init, func = filter }
