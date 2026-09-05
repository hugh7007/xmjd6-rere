-- 简码提示 + 单字模式过滤器
local mem_cleaner = require("xmjd6.mem_cleaner")

local DEFAULT_MAX_HINT = 50
local DEFAULT_MAX_COMPLETION = 30
local IDLE_TIMEOUT = 15

local function short_code(cand, env)
    if utf8.len(cand.text) < 2 then
        return nil
    end

    -- 按需加载 + 超时卸载
    local now = os.time()
    if not env.reverse then
        local ok, result = pcall(ReverseLookup, env.dict_name)
        if ok then
            env.reverse = result
        else
            return nil
        end
    end
    env.last_lookup_time = now

    local ok, lookup_result = pcall(function() return env.reverse:lookup(cand.text) end)
    if not ok or not lookup_result then
        return nil
    end

    local lookup = " " .. lookup_result .. " "
    return string.match(lookup, env.pattern_sbb)
        or string.match(lookup, env.pattern_short)
        or string.match(lookup, env.pattern_ssb)
end

local function hint(cand, input, short)
    if short and #input > #short and input:sub(1, #short) ~= short then
        cand:get_genuine().comment = cand.comment .. "〔" .. short .. "〕"
        return true
    end
    return false
end

local function filter(input, env)
    local context = env.engine.context
    local is_hint_on = context:get_option('wxw_hint')
    local is_completion_on = context:get_option('completion')
    local is_danzi_on = context:get_option('danzi_mode')
    local input_text = context.input
    local s, b = env.s, env.b

    -- 超时卸载 ReverseDb
    if env.reverse and env.last_lookup_time then
        if os.difftime(os.time(), env.last_lookup_time) > IDLE_TIMEOUT then
            env.reverse = nil
            env.last_lookup_time = nil
            collectgarbage("collect")
        end
    end

    local no_commit = not input_text:match("^o[a-z0-9]+$") and (s ~= "" and b ~= "") and (
        (input_text:len() < 4 and input_text:match("^[" .. s .. "]+$")) or
        input_text:match("^[" .. b .. "]+$")
    )

    local has_table = false
    local first = true
    local hinted = 0
    local yielded_completion = 0

    for cand in input:iter() do
        if first and no_commit then
            cand:get_genuine().comment = env.hint_text .. cand.comment
        end
        first = false

        if cand.type == 'table' then
            -- 630 提示只针对本次纯字母编码。前面带有“2.”等内容时，
            -- 候选照常显示，但不追加短码提示。
            if is_hint_on and not input_text:match("^o[a-z0-9]+$") and input_text:match("^[a-z]+$")
                and (env.max_hint == 0 or hinted < env.max_hint) then
                if hint(cand, input_text, short_code(cand, env)) then
                    hinted = hinted + 1
                end
            end
            yield(cand)
            has_table = true

        elseif cand.type == 'completion' then
            if env.max_completion > 0 and yielded_completion >= env.max_completion then
                return
            end
            local is_danzi = utf8.len(cand.text) == 1

            if is_completion_on then
                if not is_danzi_on or is_danzi then
                    yield(cand)
                    yielded_completion = yielded_completion + 1
                end
            elseif not has_table then
                if not is_danzi_on or is_danzi then
                    yield(cand)
                    return
                end
            else
                return
            end
        else
            yield(cand)
        end
    end
end

local function init(env)
    local config = env.engine.schema.config
    env.dict_name = config:get_string("translator/dictionary")
    env.b = config:get_string("topup/topup_with") or ""
    env.s = config:get_string("topup/topup_this") or ""

    if env.s ~= "" and env.b ~= "" then
        env.pattern_sbb = " ([" .. env.s .. "][" .. env.b .. "]+) "
        env.pattern_short = " ([" .. env.s .. "][" .. env.s .. "]) "
        env.pattern_ssb = " ([" .. env.s .. "][" .. env.s .. "][" .. env.b .. "]+) "
    end

    env.hint_text = config:get_string('hint_text') or '✖'
    env.max_hint = config:get_int('for_hint/max_hint_candidates') or DEFAULT_MAX_HINT
    env.max_completion = config:get_int('for_hint/max_completion_candidates') or DEFAULT_MAX_COMPLETION
    env.reverse = nil
    env.last_lookup_time = nil
    -- 注册到统一清理：iOS 键盘收起 sentinel 到达时释放 ReverseLookup
    env.mem_release = mem_cleaner.register(function()
        env.reverse = nil
        env.last_lookup_time = nil
    end)
end

local function fini(env)
    mem_cleaner.unregister(env.mem_release)
    env.mem_release = nil
    env.reverse = nil
    env.last_lookup_time = nil
    collectgarbage("collect")
end

return { init = init, func = filter, fini = fini }
