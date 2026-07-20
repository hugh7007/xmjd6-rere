--[[
单字优先过滤器优化版 来源：@浮生 https://github.com/wzxmer/rime-txjx
功能：重排序候选项，使单字或短注释项优先显示
优化点：
1. 渐进式配置加载，允许限制最大候选数
2. 提前终止迭代，避免在逐码时缓存海量候选
3. 减少冗余 utf8.len 调用，提升性能
]]

local DEFAULT_MAX_CANDIDATES = 50   -- 0 表示不限
local DEFAULT_MAX_SCAN = 100         -- 0 表示不限；限制 bq 这类海量补全码的扫描量

local function parse_conf_int(env, key, default_val)
    if not env then return default_val end
    local val = nil
    pcall(function()
        val = env.engine.schema.config:get_int((env.name_space or "xmjd6_single_char") .. "/" .. key)
    end)
    val = tonumber(val)
    if not val or val < 0 then return default_val end
    return val
end

local function get_config(env)
    if not env then
        return { max_candidates = DEFAULT_MAX_CANDIDATES, max_scan_candidates = DEFAULT_MAX_SCAN }
    end
    if not env._xmjd6_single_char_cfg then
        env._xmjd6_single_char_cfg = {
            max_candidates = parse_conf_int(env, "max_candidates", DEFAULT_MAX_CANDIDATES),
            max_scan_candidates = parse_conf_int(env, "max_scan_candidates", DEFAULT_MAX_SCAN)
        }
    end
    return env._xmjd6_single_char_cfg
end

local function is_priority_candidate(cand)
    if not cand or not cand.text then return false end
    if cand.comment and #cand.comment == 0 then return true end
    if cand.text:match('^%d%d%d%d%-%d%d%-%d%d$') then return true end
    if cand.comment == "Unix时间戳" then return true end
    local len = utf8.len(cand.text)
    return len ~= nil and len == 1
end

local function single_char_filter(input, env)
    if not input or not input.iter then return end

    local cfg = get_config(env)
    local max_candidates = cfg.max_candidates or DEFAULT_MAX_CANDIDATES
    local max_scan_candidates = cfg.max_scan_candidates or DEFAULT_MAX_SCAN
    local limit_enabled = max_candidates > 0
    local scan_limit_enabled = max_scan_candidates > 0
    local yielded = 0
    local scanned = 0
    local buffer = {}
    local buffer_size = 0

    local function can_yield_more()
        return (not limit_enabled) or (yielded < max_candidates)
    end

    local function emit(cand)
        if not cand then return true end
        if not can_yield_more() then
            return false
        end
        yield(cand)
        yielded = yielded + 1
        return true
    end

    for cand in input:iter() do
        scanned = scanned + 1
        if is_priority_candidate(cand) then
            if not emit(cand) then break end
        else
            buffer_size = buffer_size + 1
            buffer[buffer_size] = cand
        end
        if limit_enabled and not can_yield_more() then
            break
        end
        if scan_limit_enabled and scanned >= max_scan_candidates then
            break
        end
    end

    if limit_enabled and not can_yield_more() then
        return
    end

    for i = 1, buffer_size do
        if not emit(buffer[i]) then
            break
        end
    end
end

return single_char_filter
