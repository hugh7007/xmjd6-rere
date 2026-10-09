-- 空码自动回退上屏处理器
-- 当输入新字符后无候选时,上屏之前的首选,然后输入新字符
--
-- ★ 追顶总开关 topup/enabled（由 xmjd6.custom.yaml 提供；本键的默认值
--   **故意不写进 xmjd6.schema.yaml**，否则 custom 里注释掉会回落到默认值而关不掉）：
--     写 true        → 开启追顶（本处理器生效）
--     写 false       → 关闭
--     注释掉 / 缺省  → 关闭（config:get_bool 拿不到 true）
-- 另有两个强制关闭条件：
--   · translator/enable_sentence == true（流式输入）—— 与顶功处理器口径一致
--   · 追顶开启时再看下面的 empty_code_topup（只决定「作用范围/强度」）
--
-- 开关 empty_code_topup（direct_ascii/empty_code_topup 配置）—— 只影响**范围**，不是总开关：
--   开启时，对任意字母键追加后无候选的情况都做回退上屏（不限顶功键场景）。
--   例如 lks+m 无候选时，上屏 lks 的首选"劳科所"，m 作为新输入起始。
--   关闭时，仅处理顶功键连续场景（原行为）。

local kAccepted = 1
local kNoop = 2
local protected_codes = require("xmjd6.xmjd6_topup_processor").protected_codes
local candidate_order_ok, candidate_order_mod = pcall(require, "xmjd6.candidate_order")
local candidate_order_core = candidate_order_ok and candidate_order_mod and candidate_order_mod.core or nil

local function empty_code_topup_enabled(env)
    -- 静态开关，init 时已缓存到 env.empty_code_topup；缺省 false
    return env and env.empty_code_topup == true
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

-- [1010] 快符键：按这些键的语义 = 「顶出当前候选 + 该键成为新输入起点」，与码长无关。
--   快符词库 xmjd6.fuhao.dict.yaml 的 `#region <快符>` 全部以 ; 开头
--   （;q=~  ;a=!  ;w=?  ;d=、  ;k=（  …），所以这里就是分号。
--   想再加键（如 '）往这张表里补一行即可。
local QUICK_SYMBOL_KEYS = { [";"] = true }

local function processor(key_event, env)
    -- 追顶总开关：topup/enabled 未显式写 true（含被注释掉）→ 整体空转
    if not env.topup_master then
        return kNoop
    end
    -- 流式输入（enable_sentence）下无顶功，本处理器一并停用
    if env.enable_sentence then
        return kNoop
    end

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

    -- empty_code_topup 开关：开启时跳过顶功键集合检查，对所有字母键追加场景生效
    if not empty_code_topup_enabled(env) then
        local is_prev_topup = env.topup_set[prev]
        local is_topup = env.topup_set[key]
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
        -- [1010] 快符键豁免长度门：按 ; 的语义是「把当前候选顶出去、让 ; 成为新输入起点」，
        --   与前面码有多长无关 —— 630 简码多为 1~2 码（如 eu = 什么），也必须能被顶。
        --   普通字母键仍受门槛约束（lks+m 不顶）。
        if #input < min_len - 1 and not QUICK_SYMBOL_KEYS[key] then
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
    -- 追顶总开关：只有显式写 true 才开启；注释掉/缺省 → 拿不到 true → 关闭。
    env.topup_master = config:get_bool("topup/enabled") == true
    env.enable_sentence = config:get_bool("translator/enable_sentence") or false
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
    env.empty_code_topup = config:get_bool("direct_ascii/empty_code_topup") == true
end

return { init = init, func = processor }
