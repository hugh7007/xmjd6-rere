-- 优化版forTopUp  来源：@浮生 https://github.com/wzxmer/rime-txjx
local function string2set(str)
    local t = {}
    if type(str) ~= "string" then return t end
    for i = 1, #str do
        t[str:sub(i,i)] = true
    end
    return t
end

local function topup(env)
    local ctx = env.engine.context
    if not ctx:get_selected_candidate() and env.auto_clear then
        ctx:clear()
    else
        ctx:commit()
    end
end

local function processor(key_event, env)
    if key_event:release() or key_event:ctrl() or key_event:alt() then
        return 2
    end

    local ch = key_event.keycode
    if ch < 0x20 or ch >= 0x7f then
        return 2
    end

    local context = env.engine.context
    local input = context.input
    if not input then return 2 end

    local key = string.char(ch)
    if not env.alphabet[key] then
        return 2
    end

    -- 首字符状态缓存
    if #input == 0 then
        env.first_char = key
    end
    local is_first_topup = env.topup_set[env.first_char or key]

    if env.topup_command and is_first_topup then
        return 2
    end

    local input_len = utf8.len(input) or 0
    local prev = #input > 0 and input:sub(-1) or ""
    local is_topup = env.topup_set[key]
    local is_prev_topup = env.topup_set[prev]

    local min_len = context:get_option('danzi_mode') 
        and env.topup_min_danzi 
        or env.topup_min

    if is_prev_topup and not is_topup then
        topup(env)
    elseif not is_prev_topup and not is_topup and input_len >= min_len then
        topup(env)
    elseif input_len >= env.topup_max then
        topup(env)
    end

    return 2
end

local function init(env)
    local config = env.engine.schema.config
    env.topup_set = string2set(config:get_string("topup/topup_with") or "")
    env.alphabet = string2set(config:get_string("speller/alphabet") or "abcdefghijklmnopqrstuvwxyz")
    
    env.topup_min = math.max(1, config:get_int("topup/min_length") or 4)
    env.topup_min_danzi = math.max(1, config:get_int("topup/min_length_danzi") or env.topup_min)
    env.topup_max = math.max(env.topup_min, config:get_int("topup/max_length") or 6)
    
    env.auto_clear = config:get_bool("topup/auto_clear")
    env.topup_command = config:get_bool("topup/topup_command")
    env.first_char = nil  -- 初始化首字符缓存
end

return { init = init, func = processor }
