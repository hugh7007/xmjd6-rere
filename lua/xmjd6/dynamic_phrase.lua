-- dynamic_phrase.lua
-- Dynamic personal phrases for xmjd6.
-- Commands (separator is '):
--   '词'编码;   add phrase with explicit code
--   '编码;      add last commit text to code
--   'N'编码;    add last N commits joined to code
--   ''编码;     delete all entries with this code
--   ''词;       delete all entries for this text
--   ''词'编码;  delete exact text+code pair
--   ''N'编码;   delete using last N commits as text
--   '''         list all dynamic phrases; select one and press 0 to delete
--   '''筛选词    list dynamic phrases matching the filter; press 0 to delete
--   Append ; to execute on Android/Trime.

local core = require("xmjd6.dynamic_phrase_core")

local function get_commit_history()
    local state = _G.__dynamic_phrase_state
    if not state then return {} end
    return state.commit_history or (state.last_commit_text and { state.last_commit_text }) or {}
end

local function get_store_path(env)
    local file = nil
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        file = env.engine.schema.config:get_string("dynamic_phrase/store_file")
    end
    return core.store_path(file or core.default_filename)
end

local function make_candidate(seg, text, comment, quality, cand_type)
    local cand = Candidate(cand_type or "dynamic_phrase", seg.start, seg._end, text, comment or "")
    cand.quality = quality or 200000
    return cand
end

local function command_candidate(input, seg)
    local preview, comment = core.command_preview(input, get_commit_history())
    if preview then
        return make_candidate(seg, preview, (comment or "") .. "  末尾加 ; 执行；空格/回车也可", 300000)
    end

    if core.is_dynamic_command(input) then
        local _, err = core.parse_command(input)
        -- When input is bare ' or '', the candidate text should be the literal
        -- input so that space/enter commits the apostrophe(s), not the hint.
        -- The hint text goes into the comment instead.
        if input == "'" or input == "''" then
            return make_candidate(seg, input, err or "动态词命令", 300000)
        end
        return make_candidate(seg, err or "动态词命令", "单段 '码; 多段 'N'码; 末尾 ; 执行", 300000)
    end

    return nil
end

local function management_query(input)
    if type(input) ~= "string" then return nil end
    return input:match("^'''([^';]*)$")
end

local function yield_management_candidates(input, seg, env)
    local query = management_query(input)
    if query == nil then return false end

    local state = _G.__dynamic_phrase_state or {}
    local pending = state.pending_delete
    if pending and pending.input == input then
        yield(make_candidate(
            seg,
            "确认删除：" .. pending.text,
            pending.code .. "〔再按'确认，其他键取消〕",
            400000,
            "dynamic_phrase_delete_confirm"
        ))
        return true
    end

    local notice = state.manager_notice
    if notice and notice.input == input and notice.message and notice.message ~= "" then
        yield(make_candidate(
            seg,
            notice.message,
            notice.ok and "〔自造词管理〕" or "〔删除失败〕",
            500000,
            "dynamic_phrase_manager_notice"
        ))
    end

    local entries = core.search_entries(query, get_store_path(env))
    if #entries == 0 then
        if query == "" then
            yield(make_candidate(
                seg,
                "暂无自造词",
                "dynamic_phrases.txt 为空",
                400000,
                "dynamic_phrase_manager_empty"
            ))
        else
            local cmd_cand = command_candidate(input, seg)
            if cmd_cand then yield(cmd_cand) end
        end
        return true
    end

    for i, entry in ipairs(entries) do
        yield(make_candidate(
            seg,
            entry.text,
            entry.code .. "〔自造·按'删除〕",
            400000 - i,
            "dynamic_phrase_manager"
        ))
    end
    return true
end

local function translator(input, seg, env)
    if type(input) ~= "string" or input == "" then
        return
    end

    if yield_management_candidates(input, seg, env) then
        return
    end

    local cmd_cand = command_candidate(input, seg)
    if cmd_cand then
        yield(cmd_cand)
        return
    end

    -- Do not treat non-code special commands as dynamic phrase codes.
    local first = input:sub(1, 1)
    if first == "=" or first == "\\" or first == "&" or first == "/" then
        return
    end
    -- Skip when input is just apostrophes without ; or / (sentence-mode input).
    if first == "'" and not core.is_dynamic_command(input) then
        return
    end

    local matches = core.lookup(input, get_store_path(env))
    for i, entry in ipairs(matches) do
        local cand = make_candidate(seg, entry.text, entry.code .. "〔自造〕", 250000 - i)
        yield(cand)
    end
end

return translator
