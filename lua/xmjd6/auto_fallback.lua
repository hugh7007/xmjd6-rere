-- 空码自动回退上屏处理器
-- 当输入新字符后无候选时,上屏之前的首选,然后输入新字符
--
-- 开关 empty_code_topup（direct_ascii/empty_code_topup 配置）：
--   开启时，对任意字母键追加后无候选的情况都做回退上屏（不限顶功键场景）。
--   例如 lks+m 无候选时，上屏 lks 的首选"劳科所"，m 作为新输入起始。
--   关闭时，仅处理顶功键连续场景（原行为）。

local kAccepted = 1
local kNoop = 2
local protected_codes = require("xmjd6.protected_codes")
local candidate_order_ok, candidate_order_core = pcall(require, "xmjd6.candidate_order_core")

local function empty_code_topup_enabled(env)
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    if config and config.get_bool then
        local ok, value = pcall(function() return config:get_bool("direct_ascii/empty_code_topup") end)
        if ok and type(value) == "boolean" then return value end
    end
    return false
end

local function string2set(str)
    local t = {}
    if type(str) ~= "string" then
        return t
    end
    for i = 1, #str do
        t[str:sub(i, i)] = true
    end
    return t
end

local function processor(key_event, env)
    if key_event:release() or key_event:ctrl() or key_event:alt() then
        return kNoop
    end

    local ch = key_event.keycode
    if ch < 0x20 or ch >= 0x7f then
        return kNoop
    end

    local key = string.char(ch)
    if not env.alphabet[key] then
        return kNoop
    end

    local context = env.engine.context
    local input = context.input
    if env.sentence_prefix and env.sentence_prefix ~= ""
        and #input > #env.sentence_prefix
        and input and input:sub(1, #env.sentence_prefix) == env.sentence_prefix then
        return kNoop
    end
    if input and env.protected_codes[input .. key] then
        return kNoop
    end
    if input and candidate_order_ok and candidate_order_core
        and candidate_order_core.is_enabled(env)
        and candidate_order_core.has_code_prefix
        and candidate_order_core.has_code_prefix(input .. key) then
        return kNoop
    end
    -- 功能引导符开头的输入（=计算器/工具、\转字体、&Unicode）没有词库候选属正常，
    -- 不做空码回退，否则 =uuid 这类输入会被截断上屏
    local lead = input and input:sub(1, 1) or ""
    if lead == "=" or lead == "\\" or lead == "&" then
        return kNoop
    end
    local prev = #input > 0 and input:sub(-1) or ""
    local is_prev_topup = env.topup_set[prev]
    local is_topup = env.topup_set[key]

    -- empty_code_topup 开关：开启时跳过顶功键集合检查，对所有字母键追加场景生效
    if not empty_code_topup_enabled(env) then
        -- 顶功处理器已处理的常规场景跳过
        -- 仅在「连续顶功键」且当前输入有候选时，继续走空码回退检查
        -- 这样 dia+o（diao 无候选）会回退上屏 dia，而 ba+o（bao 有候选）正常继续
        if is_prev_topup and not is_topup then
            return kNoop
        end
        if not is_prev_topup and not is_topup then
            return kNoop
        end

        -- 连续顶功键场景（is_prev_topup and is_topup）：
        -- 仅当输入长度 >= min_length - 1 时才尝试回退
        -- 避免 di+a 这种短码也被回退上屏
        local min_len = context:get_option('danzi_mode')
            and (env.topup_min_danzi or 2)
            or (env.topup_min or 4)
        if #input < min_len - 1 then
            return kNoop
        end
    end
    
    -- 当前必须有候选才考虑回退（否则说明当前已经是空码状态）
    local current_cand = context:get_selected_candidate()
    if not current_cand then
        return kNoop
    end

    -- 模拟添加新字符
    context:push_input(key)
    
    -- 检查是否有候选
    local has_cand = context:get_selected_candidate() ~= nil

    if has_cand then
        -- 有候选，正常继续，已经push了所以直接返回accepted
        return kAccepted
    end

    -- 无候选，回退：删掉刚加的字符，上屏首选，再输入新字符
    context:pop_input(1)
    context:commit()
    context:push_input(key)
    return kAccepted
end

local function init(env)
    local config = env.engine.schema.config
    local alphabet_str = config:get_string("speller/alphabet") or "abcdefghijklmnopqrstuvwxyz"
    env.alphabet = {}
    for i = 1, #alphabet_str do
        env.alphabet[alphabet_str:sub(i, i)] = true
    end
    env.topup_set = string2set(config:get_string("topup/topup_with") or "")
    env.sentence_prefix = config:get_string("sentence_mode/prefix") or "'"
    env.topup_min = math.max(1, config:get_int("topup/min_length") or 4)
    env.topup_min_danzi = math.max(1, config:get_int("topup/min_length_danzi") or env.topup_min)
    env.protected_codes = protected_codes.load()
end

return { init = init, func = processor }
