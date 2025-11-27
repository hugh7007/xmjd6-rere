-- txjx filter 模块，此版本经过二次优化 来源：@浮生 https://github.com/wzxmer/rime-txjx
local function startswith(str, start)
    return string.sub(str, 1, #start) == start
end

local function hint(cand, env)
    -- 安全检查：cand.text 不能为空
    if not cand.text or utf8.len(cand.text) < 2 then
        return false
    end
    local context = env.engine.context
    local reverse = env.reverse
    local s = env.s
    local b = env.b
    
    -- 安全检查：reverse、s 和 b 必须有效
    if not reverse or s == "" or b == "" then
        return false
    end
    
    -- 安全调用 reverse:lookup，捕获可能的异常
    local ok, lookup_result = pcall(function() return reverse:lookup(cand.text) end)
    if not ok or not lookup_result then
        return false
    end
    local lookup = " " .. lookup_result .. " "
    local short = string.match(lookup, " (["..s.."]["..b.."]+) ") or 
                  string.match(lookup, " (["..s.."]["..s.."]) ") or
                  string.match(lookup, " (["..s.."]["..s.."]["..b.."]) ") or
                  string.match(lookup, " (["..b.."]["..b.."]["..b.."]) ")
    local input = context.input 
    if short and utf8.len(input) > utf8.len(short) and not startswith(short, input) then
        -- cand:get_genuine().comment = cand.comment .. "〔" .. short .. "〕"
        cand:get_genuine().comment = (cand.comment or "") .. " = " .. short
        return true
    end

    return false
end

local function danzi(cand)
    if not cand.text then
        return false
    end
    return utf8.len(cand.text) < 2
end

local function commit_hint(cand, hint_text)
    cand:get_genuine().comment = hint_text .. (cand.comment or "")
    -- cand:get_genuine().comment = cand.comment
end



local function filter(input, env)
    local engine = env.engine
    local context = engine.context
    local is_danzi = context:get_option('danzi_mode')
    local is_on = context:get_option('sbb_hint')
    local hint_text = env.hint_text
    local first = true
    local input_text = context.input
    -- 安全检查：避免空字符串导致正则表达式错误
    local no_commit = false
    if env.s ~= "" and env.b ~= "" then
        local is_short_s = input_text:len() < 4 and input_text:match("^["..env.s.."]+$") ~= nil
        local is_all_b = input_text:match("^["..env.b.."]+$") ~= nil
        no_commit = is_short_s or is_all_b
    end
    local count = 0
    for cand in input:iter() do
        -- if first and no_commit and cand.type ~= 'completion' then
        if first and no_commit then
            commit_hint(cand, hint_text)
        end
       
        first = false
        if not is_danzi or danzi(cand) then
            if is_on then
                hint(cand, env)
            end
            yield(cand)
            count = count + 1
        end
    end
    -- 每处理一定数量候选词后触发 GC
    if count > 100 then
        collectgarbage("step", 1)
    end
end

local function init(env)
    local config = env.engine.schema.config
    local dict_name = config:get_string("translator/dictionary")
    
    if not dict_name or dict_name == "" then
        error("txjx_filter: translator/dictionary not configured")
    end

    env.b = config:get_string("topup/topup_with") or ""
    env.s = config:get_string("topup/topup_this") or ""
    env.hint_text = config:get_string('hint_text') or '🚫'
    
    -- 安全初始化 ReverseDb，捕获可能的错误
    local ok, result = pcall(function()
        return ReverseDb("build/".. dict_name .. ".reverse.bin")
    end)
    if ok then
        env.reverse = result
    else
        -- 如果反查库加载失败，设为 nil，hint 函数会跳过
        env.reverse = nil
    end
end

local function fini(env)
    env.reverse = nil
    env.s = nil
    env.b = nil
    env.hint_text = nil
    collectgarbage("collect")
end

return { init = init, func = filter, fini = fini }
