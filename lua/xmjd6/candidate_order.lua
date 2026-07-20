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

local function make_candidate(seg, text, comment, quality)
    local cand = Candidate("candidate_order", seg.start, seg._end, text, comment or "")
    cand.quality = quality or 260000
    return cand
end

local function translator(input, seg, env)
    if not core.is_enabled(env) then return end
    if type(input) ~= "string" or input == "" then return end
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
