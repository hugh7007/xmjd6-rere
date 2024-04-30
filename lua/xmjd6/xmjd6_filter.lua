local function startswith(str, start)
    return string.sub(str, 1, string.len(start)) == start
end

local function safe_regex_escape(pattern)
    return pattern:gsub("%W", "%%%1")
end

local function hint(cand, env)
    if utf8.len(cand.text) < 2 then
        return false
    end
    
    local context = env.engine.context
    local reverse = env.reverse
    local s = safe_regex_escape(env.s)
    local b = safe_regex_escape(env.b)
    
    local lookup = " " .. reverse:lookup(cand.text) .. " "
    local patterns = env.patterns
    
    local input = context.input 
    local input_len = utf8.len(input)
    local short = env.short -- Make sure 'short' is defined and valid
    if short and input_len > utf8.len(short) and not startswith(short, input) then
        cand:get_genuine().comment = cand.comment .. " = " .. short
        return true
    end

    return false
end

local function danzi(cand)
    return utf8.len(cand.text) < 2
end

local function commit_hint(cand, hint_text)
    cand:get_genuine().comment = hint_text .. cand.comment
end

local function filter(input, env)
    local is_danzi = env.engine.context:get_option('danzi_mode')
    local is_on = env.engine.context:get_option('sbb_hint')
    local hint_text = env.engine.schema.config:get_string('hint_text') or '🚫'
    local input_text = env.engine.context.input
    local no_commit = (input_text:len() < 4 and input_text:match("^["..safe_regex_escape(env.s).."]+$")) or (input_text:match("^["..safe_regex_escape(env.b).."]+$"))
    
    for cand in input:iter() do
        if no_commit then
            commit_hint(cand, hint_text)
            no_commit = false
        end
        
        if not is_danzi or danzi(cand) then
            if is_on then
                hint(cand, env)
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
    env.reverse = ReverseDb("build/".. dict_name .. ".reverse.bin")
    env.patterns = {
        " (["..env.s.."]["..env.b.."]+) ",
        " (["..env.s.."]["..env.s.."]) ",
        " (["..env.s.."]["..env.s.."]["..env.b.."]) ",
        " (["..env.b.."]["..env.b.."]["..env.b.."]) "
    }
end

return { init = init, func = filter }
