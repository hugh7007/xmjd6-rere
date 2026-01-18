--[[
    txjx 顶功处理器，此版本经过二次优化 来源：@浮生 https://github.com/wzxmer/rime-txjx
    https://github.com/xkjd27/rime_jd27c/blob/e38a8c5d010d5a3933e6d6d8265c0cf7b56bfcca/rime/lua/jd27_topup.lua
    顶功处理器 by TsFreddie

    ------------
    Schema配置
    ------------
    1. 将topup.lua添加至rime.lua
        topup_processor = require("topup")
    
    2. 将topup_processor挂接在speller之前
        processors:
          ...
          - lua_processor@topup_processor
          - speller
          ...
    
    3. 配置顶功处理器
        topup:
            topup_with: "aeiov" # 顶功集合码，通常为形码
            min_length: 4  # 无顶功码自动上屏的长度
            min_length_danzi: 2  # 单字模式无顶功码自动上屏的长度（开关：danzi_mode）
            max_length: 6  # 全码上屏的长度
            auto_clear: true  # 顶功空码时是否清空输入
            topup_command: false # 为true时，首码为顶码时禁用顶功逻辑（如orq）
]]

local function string2set(str)
    local t = {}
    if type(str) ~= "string" then return t end
    for i = 1, #str do
        local c = str:sub(i,i)
        t[c] = true
    end
    return t
end

local function topup(env)
    if not env.engine.context:get_selected_candidate() then
        if env.auto_clear then
            env.engine.context:clear()
        end
    else
        env.engine.context:commit()
        collectgarbage("collect")
    end
end

local function processor(key_event, env)
    local engine = env.engine
    local context = engine.context

    local input = context.input 
    local input_len = #input

    local min_len = env.topup_min
    if context:get_option('danzi_mode') then
        min_len = env.topup_min_danzi
    end

    if key_event:release() or key_event:ctrl() or key_event:alt() then
        return 2
    end

    local ch = key_event.keycode

    if ch < 0x20 or ch >= 0x7f then
        return 2
    end

    local key = string.char(ch)
    local prev = string.sub(input, -1)
    local first = string.sub(input, 1, 1)
    if #first == 0 then
        first = key
    end

    local is_alphabet = env.alphabet[key] or false
    local is_topup = env.topup_set[key] or false
    local is_prev_topup = env.topup_set[prev] or false
    local is_first_topup = env.topup_set[first] or false


    if env.topup_command and is_first_topup then
        return 2
    end

    if not is_alphabet then
        return 2
    end
    
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
    env.alphabet = string2set(config:get_string("speller/alphabet") or "")
    env.topup_min = config:get_int("topup/min_length") or 4
    env.topup_min_danzi = config:get_int("topup/min_length_danzi") or env.topup_min
    env.topup_max = config:get_int("topup/max_length") or 6
    env.auto_clear = config:get_bool("topup/auto_clear") or false
    env.topup_command = config:get_bool("topup/topup_command") or false
end

local function fini(env)
    env.topup_set = nil
    env.alphabet = nil
    env.topup_min = nil
    env.topup_min_danzi = nil
    env.topup_max = nil
    env.auto_clear = nil
    env.topup_command = nil
end

return { init = init, func = processor, fini = fini }