-- candidate_order.lua
-- Runtime translator for candidate_order.txt.

local core = require("xmjd6.candidate_order_core")

local function get_store_file(env)
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        local file = env.engine.schema.config:get_string("candidate_order/store_file")
        if file and file ~= "" then return file end
    end
    return core.default_filename
end

local function make_candidate(seg, text, comment, quality, cand_type)
    local cand = Candidate(cand_type or "candidate_order", seg.start, seg._end, text, comment or "")
    cand.quality = quality or 260000
    return cand
end

local function management_query(input)
    if type(input) ~= "string" then return nil end
    return input:match("^=tp(.*)$")
end

local function management_comment(rec)
    local moved = "下移"
    if rec.new_code and rec.new_code ~= "" then moved = "→" .. rec.new_code end
    return "原码" .. rec.old_code .. "；" .. rec.displaced .. moved
        .. "〔调频·第" .. tostring(rec.line_no) .. "行·按0撤销〕"
end

local function yield_management_candidates(input, seg, env)
    local query = management_query(input)
    if query == nil then return false end

    local state = _G.__candidate_order_manager_state or {}
    local pending = state.pending_delete
    if pending and pending.input == input and pending.record then
        local rec = pending.record
        yield(make_candidate(
            seg,
            "确认撤销：" .. rec.target_code .. " / " .. rec.promoted,
            "恢复" .. rec.displaced .. "〔再按0确认，其他键取消〕",
            600000,
            "candidate_order_delete_confirm"
        ))
        return true
    end

    local notice = state.manager_notice
    if notice and notice.input == input and notice.message and notice.message ~= "" then
        yield(make_candidate(
            seg,
            notice.message,
            notice.ok and "〔调频管理〕" or "〔撤销失败〕",
            600000,
            "candidate_order_manager_notice"
        ))
    end

    local records = core.search_records(query, get_store_file(env))
    if #records == 0 then
        yield(make_candidate(
            seg,
            query == "" and "暂无动态调频" or "没有匹配的动态调频",
            "candidate_order.txt",
            500000,
            "candidate_order_manager_empty"
        ))
        return true
    end

    for i, rec in ipairs(records) do
        yield(make_candidate(
            seg,
            rec.target_code .. "：" .. rec.promoted .. "置顶",
            management_comment(rec),
            500000 - i,
            "candidate_order_manager"
        ))
    end
    return true
end

local function translator(input, seg, env)
    if type(input) ~= "string" or input == "" then return end
    if yield_management_candidates(input, seg, env) then return end
    if not core.is_enabled(env) then return end
    if not input:match("^[a-z]+$") then return end

    local target_records, new_records, data = core.records_for_input(input, get_store_file(env))

    if data and data.errors and #data.errors > 0 and input == "coerr" then
        for i, err in ipairs(data.errors) do
            yield(make_candidate(seg, err, "candidate_order.txt", 300000 - i))
        end
        return
    end

    for i, rec in ipairs(target_records) do
        -- Promoted candidate should look natural: no "调频" prompt in the comment.
        yield(make_candidate(seg, rec.promoted, "", 280000 - i * 2))

        -- Keep the displaced original first candidate visible under the same input,
        -- but show the remaining completion in the comment, e.g. qzyw 下显示 兆运(~u).
        if rec.new_code and rec.new_code ~= "" then
            local hint = rec.new_code
            if rec.new_code:sub(1, #input) == input and #rec.new_code > #input then
                hint = "~" .. rec.new_code:sub(#input + 1)
            end
            yield(make_candidate(seg, rec.displaced, hint, 279999 - i * 2))
        end
    end

    for i, rec in ipairs(new_records) do
        if rec.new_code and rec.new_code:sub(1, #input) == input then
            -- At the actual new code, do not show an extra prompt; at an
            -- intermediate prefix, mimic table completion and show the rest.
            -- Prefix completion must stay below normal table exact candidates
            -- (translator.initial_quality is 0), otherwise a displaced word can
            -- jump ahead of the real exact word at that prefix, e.g.
            -- ytyda: 源由 should stay above 缘由(~i).
            local hint = ""
            local quality = 270000 - i
            if #input < #rec.new_code then
                hint = "~" .. rec.new_code:sub(#input + 1)
                quality = -10 - i
            end
            yield(make_candidate(seg, rec.displaced, hint, quality))
        end
    end
end

return translator
