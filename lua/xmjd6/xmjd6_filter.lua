-- 优化版filter  来源：@浮生 https://github.com/wzxmer/rime-txjx
local function escape_pattern(s)
    return s and s:gsub("([%-%]%^])", "%%%1") or ""
end

local function startswith(str, start)
    if type(str) ~= "string" or type(start) ~= "string" then return false end
    if #start == 0 then return true end
    if #str < #start then return false end
    return string.sub(str, 1, #start) == start
end

local function hint(cand, env)
    if utf8.len(cand.text) < 2 then
        return false
    end
    local context = env.engine.context
    local reverse = env.reverse
    local s = env.s and escape_pattern(env.s) or ''
    local b = env.b and escape_pattern(env.b) or ''
    if s == '' and b == '' then return false end
    
    local lookup = " " .. reverse:lookup(cand.text) .. " "
    local short
    
    -- 严格保持原始匹配顺序
    if #s > 0 and #b > 0 then
        short = string.match(lookup, " (["..s.."]["..s.."]["..b.."]) ") or
                string.match(lookup, " (["..b.."]["..b.."]["..b.."]) ") or
                string.match(lookup, " (["..s.."]["..b.."]+) ") or
                string.match(lookup, " (["..s.."]["..s.."]) ")
    elseif #s > 0 then
        short = string.match(lookup, " (["..s.."]["..s.."]) ")
    elseif #b > 0 then
        short = string.match(lookup, " (["..b.."]["..b.."]) ")
    end
    
    local input = context.input 
    if short and utf8.len(input) > utf8.len(short) and not startswith(short, input) then
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
    cand:get_genuine().comment = hint_text .. (cand.comment or "")
end

local function filter(input, env)
    local is_danzi = env.engine.context:get_option('danzi_mode')
    local is_on = env.engine.context:get_option('sbb_hint')
    local hint_text = env.engine.schema.config:get_string('hint_text') or '🚫'
    local first = true
    local input_text = env.engine.context.input
    local s = env.s and escape_pattern(env.s) or ''
    local b = env.b and escape_pattern(env.b) or ''
    
    local no_commit = (input_text:len() < 4 and s ~= '' and input_text:match("^["..s.."]+$")) or 
                     (b ~= '' and input_text:match("^["..b.."]+$"))
    
    for cand in input:iter() do
        if first and no_commit then
            commit_hint(cand, hint_text)
        end
        first = false
        
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

    env.b = config:get_string("topup/topup_with") or ""
    env.s = config:get_string("topup/topup_this") or ""
    env.reverse = ReverseLookup(dict_name)
end

return { init = init, func = filter }
