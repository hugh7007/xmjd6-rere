-- 优化版候选词过滤器
-- 功能：
--   1. 提示字（sbb_hint）：显示候选词的简码提示
--   2. 单字模式（danzi_mode）：只显示单字候选
--   3. 内存管理：按需加载 ReverseDb，闲置后自动卸载，配合增量 GC 控制内存
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-01-25

local gc = require("xmjd6.xmjd6_gc")

local function startswith(str, start)
    return string.sub(str, 1, #start) == start
end

-- 为候选词添加简码提示
local function hint(cand, env)
    -- 只跳过单字候选（简码提示仅针对多字词）
    if not cand.text then return false end
    local char_len = utf8.len(cand.text)
    if not char_len or char_len < 2 then
        return false
    end

    local now = os.time()
    -- 按需加载 ReverseLookup，失败后进入冷却期避免反复尝试
    if not env.reverse and env.dict_name and not (env.reverse_retry_after and now < env.reverse_retry_after) then
        local ok, result = pcall(ReverseLookup, env.dict_name)
        if ok and result then
            env.reverse = result
            env.reverse_retry_after = nil
        else
            -- 加载失败，进入冷却期（2 秒）
            env.reverse_retry_after = now + 2
        end
    end

    if env.reverse then
        env.last_lookup_time = now
    end

    local context = env.engine.context
    local reverse = env.reverse
    local s = env.s
    local b = env.b

    if not reverse or s == "" or b == "" then
        return false
    end

    -- 调用 reverse:lookup，捕获可能的异常
    local ok, lookup_result = pcall(reverse.lookup, reverse, cand.text)
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
        cand:get_genuine().comment = (cand.comment or "") .. " = " .. short
        return true
    end

    return false
end

-- 判断是否为单字候选
local function danzi(cand)
    if not cand.text then
        return false
    end
    return utf8.len(cand.text) < 2
end

-- 为首候选添加提交提示
local function commit_hint(cand, hint_text)
    cand:get_genuine().comment = hint_text .. (cand.comment or "")
end

-- 主过滤函数
local function filter(input, env)
    local engine = env.engine
    local context = engine.context
    local is_danzi = context:get_option('danzi_mode')
    local is_on = context:get_option('sbb_hint')
    local hint_text = env.hint_text
    local first = true
    local input_text = context.input

    -- 自动卸载闲置的 ReverseDb（5 秒超时），释放内存
    if env.reverse and env.last_lookup_time then
        local now = os.time()
        if os.difftime(now, env.last_lookup_time) > 5 then
            env.reverse = nil
            gc.full(env)
            env.last_lookup_time = nil
        end
    end

    -- 定期执行 full GC（15 秒间隔），防止 iOS 切换 APP 后内存累积
    if not env.last_active_full_gc then
        env.last_active_full_gc = os.time()
    else
        local now_full = os.time()
        if os.difftime(now_full, env.last_active_full_gc) >= 15 then
            gc.full(env)
            env.last_active_full_gc = now_full
        end
    end

    -- 判断是否需要显示提交提示（短声母或全笔画输入）
    local no_commit = false
    if env.s ~= "" and env.b ~= "" then
        local is_short_s = input_text:len() < 4 and input_text:match("^["..env.s.."]+$") ~= nil
        local is_all_b = input_text:match("^["..env.b.."]+$") ~= nil
        no_commit = is_short_s or is_all_b
    end

    -- 记录已显示过简码提示的候选词，避免重复提示
    local hinted = {}
    local count = 0
    for cand in input:iter() do
        -- 为首候选添加提交提示
        if first and no_commit then
            commit_hint(cand, hint_text)
        end

        first = false
        if not is_danzi or danzi(cand) then
            -- 只对第一次出现的候选词显示简码提示
            if is_on and cand.text and not hinted[cand.text] then
                if hint(cand, env) then
                    hinted[cand.text] = true
                end
            end
            yield(cand)
            count = count + 1
        end
    end
    -- 每轮处理完记 10 点，累积 50 触发增量 GC
    gc.tick(env, 10)
end

-- 初始化函数
local function init(env)
    local config = env.engine.schema.config
    local dict_name = config:get_string("translator/dictionary")

    if not dict_name or dict_name == "" then
        error("xmjd6_filter: translator/dictionary not configured")
    end

    env.dict_name = dict_name
    env.b = config:get_string("topup/topup_with") or ""
    env.s = config:get_string("topup/topup_this") or ""
    env.hint_text = config:get_string('hint_text') or '🚫'
    -- 启动时执行一次 full GC，清理上次会话残留
    gc.full(env)
    gc.init(env, { step_every = 50, step_k = 1, weight = 10 })
    env.reverse = nil
    env.last_lookup_time = nil
    env.reverse_retry_after = nil
    env.last_active_full_gc = os.time()
end

-- 清理函数
local function fini(env)
    env.reverse = nil
    env.s = nil
    env.b = nil
    env.hint_text = nil
    gc.full(env)
end

return { init = init, func = filter, fini = fini }
