local function startswith(str, start)
    return string.sub(str, 1, string.len(start)) == start
end

local function hint(cand, context, reverse)
    if utf8.len(cand.text) < 2 then
        return false
    end
    
    local lookup = " " .. reverse:lookup(cand.text) .. " "
    local short = string.match(lookup, " ([bcdefghjklmnpqrstwxyz][auiov]+) ") or 
                  string.match(lookup, " ([bcdefghjklmnpqrstwxyz][bcdefghjklmnpqrstwxyz]) ")
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
    local is_on = env.engine.context:get_option('sbb_hint')
    local hint_text = env.engine.schema.config:get_string('hint_text') or '🚫'
    local first = true
    local input_text = env.engine.context.input
    local no_commit = (input_text:len() < 4 and input_text:match("^[bcdefghjklmnpqrstwxyz]+$")) or (input_text:match("^[avuio]+$"))
    for cand in input:iter() do
        -- if first and no_commit and cand.type ~= 'completion' then
        if first and no_commit then
            commit_hint(cand, hint_text)
        end
       
        first = false
        if not is_danzi or danzi(cand) then
            if is_on then
            hint(cand, env.engine.context, env.reverse)
            end
            yield(cand)
        end
    end
end

local function init(env)
    env.reverse = ReverseDb("build/xmjd6.extended.reverse.bin")
end

return { init = init, func = filter }
