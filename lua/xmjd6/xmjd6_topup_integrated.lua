-- 整合顶功处理器
-- 合并 xmjd6_smart_2（占位）+ xmjd6_topup_processor（顶功）+ auto_fallback（空码回退）
-- 当 translator/enable_sentence 为 true 时，自动禁用顶功和空码回退，
-- 整句模式下 ;' 号只作为分隔符，不执行顶功上屏。
-- 原始功能保留：顶功、空码回退、保护码、调频挪码保护、功能引导符跳过、整句前缀跳过。

local protected_codes = require("xmjd6.protected_codes")
local candidate_order_ok, candidate_order_core = pcall(require, "xmjd6.candidate_order_core")

local kAccepted = 1
local kNoop = 2

local function string2set(str)
    local t = {}
    if type(str) ~= "string" then return t end
    for i = 1, #str do
        t[str:sub(i, i)] = true
    end
    return t
end

-- 顶功执行：上屏当前首选并清空或保留
local function topup(env)
    local ctx = env.engine.context
    if ctx:get_selected_candidate() then
        ctx:commit()
    elseif env.auto_clear then
        ctx:clear()
    end
end

local function processor(key_event, env)
    if key_event:release() or key_event:ctrl() or key_event:alt() then
        return kNoop
    end

    local ch = key_event.keycode
    if ch < 0x20 or ch >= 0x7f then
        return kNoop
    end

    local context = env.engine.context
    local input = context.input
    if not input then return kNoop end

    local key = string.char(ch)
    if not env.alphabet[key] then
        return kNoop
    end

    -- 整句模式前缀开头的输入不参与顶功/空码回退
    if env.sentence_prefix and env.sentence_prefix ~= ""
        and #input > #env.sentence_prefix
        and input:sub(1, #env.sentence_prefix) == env.sentence_prefix then
        return kNoop
    end

    -- 功能引导符开头的输入（=计算器/工具、\转字体、&Unicode）不参与顶功/空码回退
    local lead = input:sub(1, 1)
    if lead == "=" or lead == "\\" or lead == "&" then
        return kNoop
    end

    -- 保护码不顶功/不回退
    local next_code = input .. key
    if env.protected_codes[next_code] then
        return kNoop
    end

    -- 调频挪码保护
    if candidate_order_ok and candidate_order_core
        and candidate_order_core.is_enabled(env)
        and candidate_order_core.has_code_prefix
        and candidate_order_core.has_code_prefix(next_code) then
        return kNoop
    end

    -- ===== 整句模式检测 =====
    -- 当 translator/enable_sentence 为 true 时，禁用顶功和空码回退
    -- ;' 号只作为分隔符，由 speller 处理
    if env.enable_sentence then
        return kNoop
    end

    -- ===== 顶功逻辑（原 xmjd6_topup_processor）=====

    local first = #input > 0 and input:sub(1, 1) or key
    if env.topup_command and env.topup_set[first] then
        return kNoop
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

    -- ===== 空码回退逻辑（原 auto_fallback）=====
    -- 顶功处理器返回 kNoop 让按键继续传递给 speller
    -- 空码回退在顶功之后检测：顶功没触发时，检查新字符是否导致空码
    -- 注意：顶功可能已经 commit + clear，此时 input 为空，空码回退自然跳过

    -- 重新获取 input（顶功可能已修改 context）
    input = context.input
    if not input or #input < 1 then
        return kNoop
    end

    -- 顶功字符开头的码不做空码回退
    if env.topup_set[input:sub(-1)] then
        return kNoop
    end

    -- 当前必须有候选才考虑回退
    local current_cand = context:get_selected_candidate()
    if not current_cand then
        return kNoop
    end

    -- 模拟添加新字符检查是否有候选
    context:push_input(key)
    local has_cand = context:get_selected_candidate() ~= nil

    if has_cand then
        -- 有候选，正常继续
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
    env.topup_set = string2set(config:get_string("topup/topup_with") or "")
    env.alphabet = string2set(config:get_string("speller/alphabet") or "abcdefghijklmnopqrstuvwxyz")
    env.topup_min = math.max(1, config:get_int("topup/min_length") or 4)
    env.topup_min_danzi = math.max(1, config:get_int("topup/min_length_danzi") or env.topup_min)
    env.topup_max = math.max(env.topup_min, config:get_int("topup/max_length") or 6)
    env.auto_clear = config:get_bool("topup/auto_clear")
    env.topup_command = config:get_bool("topup/topup_command")
    env.protected_codes = protected_codes.load()
    env.sentence_prefix = config:get_string("sentence_mode/prefix") or "'"

    -- 读取 translator/enable_sentence 配置
    -- 当 enable_sentence 为 true 时，自动禁用顶功和空码回退
    local sentence_val = config:get_bool("translator/enable_sentence")
    if sentence_val == nil then
        local text = config:get_string("translator/enable_sentence")
        if text == "true" or text == "1" or text == "on" or text == "yes" then
            sentence_val = true
        else
            sentence_val = false
        end
    end
    env.enable_sentence = sentence_val
end

local function fini(env)
    env.topup_set = nil
    env.alphabet = nil
    env.protected_codes = nil
end

return { init = init, func = processor, fini = fini }
