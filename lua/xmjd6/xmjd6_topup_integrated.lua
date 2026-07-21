-- 整合顶功处理器
-- 合并 xmjd6_smart_2（占位）+ xmjd6_topup_processor（顶功）+ auto_fallback（空码回退）
-- 当 translator/enable_sentence 为 true 时，自动禁用顶功和空码回退。
--
-- 参考浮生方案（https://github.com/wzxmer/rime-xmjd6）的顶功逻辑：
--   1. 候选类型感知：只提交非 completion、非 raw_input 的候选
--   2. 空码回退探测加固：push 后校验 input 是否真的被追加，pop 后校验是否恢复
--   3. 顶功执行后返回 kNoop，让 speller 自然接收按键
--   4. 空码回退 commit 后也返回 kNoop

local protected_codes = require("xmjd6.protected_codes")
local candidate_order_ok, candidate_order_core = pcall(require, "xmjd6.candidate_order_core")

local kAccepted = 1
local kNoop = 2

-- ===== 调试日志 =====
local DEBUG = true
local function debug_log(msg)
    if not DEBUG then return end
    local f = io.open("C:/Users/yao/AppData/Roaming/Rime/topup_debug.log", "a")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f:close()
    end
end

local string_byte = string.byte
local string_sub = string.sub
local string_find = string.find
local string_match = string.match

local RAW_INPUT_PATTERN = "^[a-z;'" .. "]+$"

-- ===== 候选类型判断（参考浮生 commit_guard） =====

local function candidate_type(cand)
    if not cand then return nil end
    local cand_type = cand.type
    if cand.get_genuine then
        local ok, genuine = pcall(function() return cand:get_genuine() end)
        if ok and genuine and genuine.type then cand_type = genuine.type end
    end
    return cand_type
end

local function is_completion_candidate(cand)
    return candidate_type(cand) == "completion"
end

local function is_raw_input_candidate(ctx, cand)
    local input = ctx and (ctx.input or "") or ""
    if input == "" or not cand or cand.text ~= input then return false end
    local cand_type = candidate_type(cand)
    return cand_type == "raw" or cand_type == "ascii" or string_match(input, RAW_INPUT_PATTERN) ~= nil
end

local function selected_candidate(ctx)
    return ctx and ctx:get_selected_candidate() or nil
end

-- 只提交非 completion、非 raw_input 的候选
local function commit_selected_non_completion(ctx)
    local cand = selected_candidate(ctx)
    if not cand or is_completion_candidate(cand) or is_raw_input_candidate(ctx, cand) then
        return false
    end
    ctx:commit()
    return true
end

-- 检查是否存在非 completion、非 raw_input 的候选
local function has_non_completion_candidate(ctx)
    local selected = ctx:get_selected_candidate()
    if selected then
        return not is_completion_candidate(selected) and not is_raw_input_candidate(ctx, selected)
    end
    -- 回退检查 composition menu
    local comp = ctx.composition and ctx.composition:back()
    local menu = comp and comp.menu
    if not menu then return false end
    local ok, cand = pcall(function() return menu:get_candidate_at(0) end)
    return ok and cand ~= nil
        and not is_completion_candidate(cand)
        and not is_raw_input_candidate(ctx, cand)
end

-- ===== 工具函数 =====

local function string2set(str)
    local t = {}
    if type(str) ~= "string" then return t end
    for i = 1, #str do
        t[str:sub(i, i)] = true
    end
    return t
end

-- 顶功执行：上屏当前首选（排除 raw_input）或清空
-- 返回 committed (bool): 是否成功提交或清空了 context
local function topup(env)
    local ctx = env.engine.context
    local cand = ctx:get_selected_candidate()
    if cand then
        -- raw_input 候选不提交（输入本身作为候选无意义）
        if is_raw_input_candidate(ctx, cand) and not env.auto_clear then
            return false
        end
        ctx:commit()
        return true
    elseif env.auto_clear then
        ctx:clear()
        return true
    end
    return false
end

-- 顶功规则判断：当前输入+新键是否应触发顶功
local function fixed_rule_would_commit(env, input, key, min_len)
    local input_len = #input
    if input_len < 1 then return false end

    local prev = string_sub(input, -1)
    local first = string_sub(input, 1, 1)
    local is_topup = env.topup_set[key]
    local is_prev_topup = env.topup_set[prev]
    local is_first_topup = env.topup_set[first]

    -- 顶功指令模式：顶功字符开头不顶功
    if env.topup_command and is_first_topup then return false end

    -- 超过最大长度
    if input_len >= env.topup_max then return true end

    -- 上一字符是顶功字符，当前不是 → 顶功
    if is_prev_topup and not is_topup then return true end

    -- 都不是顶功字符且长度够 → 顶功
    local effective_min = min_len or env.topup_min
    if input_len >= effective_min and not is_prev_topup and not is_topup then return true end

    return false
end

-- ===== 主处理函数 =====

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

    -- 调试：记录所有进入顶功处理的按键
    if #input >= 3 then
        local has_cand = has_non_completion_candidate(context) and "yes" or "no"
        debug_log(string.format("KEY: input=%s key=%s len=%d cand=%s topup_set=%d", input, key, #input, has_cand, (function() local n=0; for _ in pairs(env.topup_set) do n=n+1 end; return n end)()))
    end

    -- 整句模式前缀开头的输入不参与顶功/空码回退
    if env.sentence_prefix and env.sentence_prefix ~= ""
        and #input > #env.sentence_prefix
        and string_sub(input, 1, #env.sentence_prefix) == env.sentence_prefix then
        return kNoop
    end

    -- 功能引导符开头的输入（=计算器/工具、\转字体、&Unicode）不参与顶功/空码回退
    local lead = string_sub(input, 1, 1)
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
    if env.enable_sentence then
        return kNoop
    end

    -- ===== 顶功逻辑 =====
    -- 单字模式调整最小长度
    local min_len = env.topup_min
    if context:get_option('danzi_mode') then
        min_len = env.topup_min_danzi
    end

    if fixed_rule_would_commit(env, input, key, min_len) then
        local cand = selected_candidate(context)
        local cand_type = candidate_type(cand)
        debug_log(string.format("TOPUP HIT: input=%s key=%s cand_type=%s cand_text=%s", input, key, tostring(cand_type), cand and cand.text or "nil"))
        local committed = topup(env)
        debug_log(string.format("TOPUP committed=%s auto_clear=%s", tostring(committed), tostring(env.auto_clear)))
        if not committed then
            -- 顶功规则命中但无法提交（候选为 completion/raw_input 且未开 auto_clear）
            -- 吞掉按键，防止 speller 把新字符追加到未清空的旧输入后面
            return kAccepted
        end
        return kNoop
    end

    -- ===== 空码回退逻辑 =====
    -- 顶功未触发时，检查新字符是否导致空码

    -- 整句流式模式不做空码回退
    if env.enable_sentence then return kNoop end

    -- 顶功字符开头的码不做空码回退
    local prev_char = #input > 0 and string_sub(input, -1) or ""
    if env.topup_set[prev_char] then
        return kNoop
    end

    -- 当前必须有候选才考虑回退（completion 也算有效候选）
    local current_cand = context:get_selected_candidate()
    if not current_cand then
        return kNoop
    end

    -- 模拟添加新字符检查是否有候选
    local current_input = context.input or ""
    context:push_input(key)

    -- push 后校验：input 是否真的被追加
    local pushed_input = context.input or ""
    if #pushed_input <= #current_input
        or string_sub(pushed_input, 1, #current_input) ~= current_input then
        -- push 没生效（时序问题），放弃回退
        return kAccepted
    end

    -- push 后有候选 → 正常继续（completion 也算）
    if context:get_selected_candidate() then
        return kAccepted
    end

    -- 无候选，回退：pop 掉刚加的字符
    context:pop_input(1)

    -- pop 后校验：input 是否恢复原状
    if (context.input or "") ~= current_input then
        -- pop 没生效，不能确保状态正确，放弃
        return kAccepted
    end

    -- 上屏当前首选（空码回退时不管候选类型，与参考方案一致）
    local fallback_cand = context:get_selected_candidate()
    if fallback_cand then
        context:commit()
    elseif env.auto_clear then
        context:clear()
    else
        return kAccepted
    end

    return kNoop
end

local function init(env)
    local config = env.engine.schema.config

    local function safe_string(key, default)
        local ok, val = pcall(function() return config:get_string(key) end)
        return (ok and val) and val or default
    end
    local function safe_int(key, default)
        local ok, val = pcall(function() return config:get_int(key) end)
        local n = (ok and val) and val or default
        return math.max(1, tonumber(n) or default)
    end
    local function safe_bool(key, default)
        local ok, val = pcall(function() return config:get_bool(key) end)
        if ok and type(val) == "boolean" then return val end
        -- 尝试 get_string 回退
        local ok2, sval = pcall(function() return config:get_string(key) end)
        if ok2 and sval then
            return sval == "true" or sval == "1" or sval == "on" or sval == "yes"
        end
        return default
    end

    env.topup_set = string2set(safe_string("topup/topup_with", "avuio;"))
    env.alphabet = string2set(safe_string("speller/alphabet", "abcdefghijklmnopqrstuvwxyz"))
    env.topup_min = safe_int("topup/min_length", 4)
    env.topup_min_danzi = safe_int("topup/min_length_danzi", env.topup_min)
    env.topup_max = math.max(env.topup_min, safe_int("topup/max_length", 6))
    env.auto_clear = safe_bool("topup/auto_clear", false)
    env.topup_command = safe_bool("topup/topup_command", false)
    env.protected_codes = protected_codes.load(config)
    env.sentence_prefix = safe_string("sentence_mode/prefix", "'")

    -- 读取 translator/enable_sentence 配置
    env.enable_sentence = safe_bool("translator/enable_sentence", false)

    debug_log(string.format("INIT: topup_set=%s min=%d max=%d auto_clear=%s topup_command=%s sentence=%s prefix=%s",
        safe_string("topup/topup_with", "?"), env.topup_min, env.topup_max,
        tostring(env.auto_clear), tostring(env.topup_command),
        tostring(env.enable_sentence), tostring(env.sentence_prefix)))
end

local function fini(env)
    env.topup_set = nil
    env.alphabet = nil
    env.protected_codes = nil
end

return { init = init, func = processor, fini = fini }
