local function startswith(str, start)
    return string.sub(str, 1, string.len(start)) == start
end

local function hint(cand, env)
    if utf8.len(cand.text) < 2 then
        return false
    end
    local context = env.engine.context
    local reverse = env.reverse
    local s = env.s
    local b = env.b

    local lookup = " " .. reverse:lookup(cand.text) .. " "
    local short = string.match(lookup, " ([" .. s .. "][" .. b .. "]+) ") or
                      string.match(lookup, " ([" .. s .. "][" .. s .. "]) ") or
                      string.match(lookup, " ([" .. s .. "][" .. s .. "][" .. b .. "]) ") or
                      string.match(lookup, " ([" .. b .. "][" .. b .. "][" .. b .. "]) ")
    local input = context.input
    if short and utf8.len(input) > utf8.len(short) and not startswith(short, input) then
        -- cand:get_genuine().comment = cand.comment .. "〔" .. short .. "〕"
        cand:get_genuine().comment = cand.comment .. " = " .. short
        return true
    end

    return false
end

local function danzi(cand)
    if utf8.len(cand.text) < 2 then
        return true
    end
    return false
end

local function commit_hint(cand, hint_text)
    cand:get_genuine().comment = hint_text .. cand.comment
    -- cand:get_genuine().comment = cand.comment
end

local function filter(input, env)
    local is_danzi = env.engine.context:get_option('danzi_mode')
    local is_630_hint_on = env.engine.context:get_option('sbb_hint')
    local hint_text = env.engine.schema.config:get_string('hint_text') or '🚫'
    local first = true
    local input_text = env.engine.context.input
    local no_commit = (input_text:len() < 4 and input_text:match("^[" .. env.s .. "]+$")) or
                          (input_text:match("^[" .. env.b .. "]+$"))
    for cand in input:iter() do
        -- if first and no_commit and cand.type ~= 'completion' then
        if first and no_commit then
            commit_hint(cand, hint_text)
        end

        first = false
        if not is_danzi or danzi(cand) then
            local has_630 = false
            if is_630_hint_on then
                has_630 = hint(cand, env)
            end
            yield(cand)
        end

    end
end

local function init(env)
    local config = env.engine.schema.config
    local dict_name = config:get_string("translator/dictionary")

    env.b = config:get_string("topup/topup_with")
    env.s = config:get_string("topup/topup_this")
    -- env.reverse = ReverseDb("build/".. dict_name .. ".reverse.bin")
    env.reverse = ReverseLookup(dict_name)
end

return {
    init = init,
    func = filter
}
