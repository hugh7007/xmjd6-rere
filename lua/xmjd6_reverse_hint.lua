-- 万能符反查读音补全
-- 只在 reverse_lookup 模式下运行，把 xmjd6.cx 中的单字读音拼入注释。
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-08

local M = {}

local DEFAULT_PRON_CACHE_LIMIT = 256
local MAX_PRON_CACHE_LIMIT = 512
local MIN_PRON_CACHE_LIMIT = 64

local pron_cache = {}
local pron_cache_count = 0
local reverse_handle = nil
local reverse_open_failed = false
local active_envs = 0

local function clear_pron_cache()
    pron_cache = {}
    pron_cache_count = 0
end

local function release_pron_cache()
    clear_pron_cache()
    collectgarbage("step", 48)
end

local function open_reverse(env)
    if reverse_handle then return true end
    if reverse_open_failed then return false end
    local dict_name = env._cx_dict or "xmjd6.cx"
    local ok, handle = pcall(ReverseLookup, dict_name)
    if ok and handle then
        reverse_handle = handle
        return true
    end
    reverse_open_failed = true
    return false
end

local function lookup_pron(text, env)
    if not text or utf8.len(text) ~= 1 then
        return nil
    end

    local cached = pron_cache[text]
    if cached ~= nil then
        return cached or nil
    end

    if not open_reverse(env) then
        pron_cache[text] = false
        return nil
    end

    local result = reverse_handle:lookup(text)
    local pron = nil
    if result and result ~= "" then
        pron = result:match("%(([^%)]+)%)")
    end

    if pron_cache_count >= (env._pron_cache_limit or DEFAULT_PRON_CACHE_LIMIT) then
        clear_pron_cache()
    end
    pron_cache[text] = pron or false
    pron_cache_count = pron_cache_count + 1
    return pron
end

local function is_reverse_lookup(env)
    local ctx = env.engine.context
    local seg = ctx and ctx.composition and ctx.composition:back()
    if not seg then
        return false
    end
    if seg.has_tag and seg:has_tag("reverse_lookup") then
        return true
    end
    return seg.tag == "reverse_lookup"
end

local function merge_comment(pron, comment)
    comment = comment or ""
    if comment:find(" | ", 1, true) then
        return comment
    end
    if comment:match("^%[.*%]$") then
        return "[" .. pron .. " | " .. comment:sub(2, -2) .. "]"
    end
    if comment ~= "" then
        return "[" .. pron .. " | " .. comment .. "]"
    end
    return "[" .. pron .. "]"
end

function M.func(input, env)
    if not is_reverse_lookup(env) then
        release_pron_cache()
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    for cand in input:iter() do
        if cand.text and utf8.len(cand.text) == 1 then
            local p = lookup_pron(cand.text, env)
            if p then
                cand:get_genuine().comment = merge_comment(p, cand.comment)
            end
        end
        yield(cand)
    end
end

function M.fini(env)
    release_pron_cache()
    if active_envs > 0 then
        active_envs = active_envs - 1
    end
    if active_envs == 0 then
        if reverse_handle and reverse_handle.close then
            pcall(function() reverse_handle:close() end)
        end
        reverse_handle = nil
        reverse_open_failed = false
    end
end

function M.init(env)
    active_envs = active_envs + 1
    reverse_open_failed = false

    local config = env.engine.schema.config
    local keyword = config:get_string("dict_keywords") or env.engine.schema.schema_id or "xmjd6"
    keyword = keyword:match("^[^,%s;|]+") or "xmjd6"
    env._cx_dict = keyword .. ".cx"

    local pron_cache_limit = config:get_int("pron_cache_limit") or DEFAULT_PRON_CACHE_LIMIT
    if pron_cache_limit < MIN_PRON_CACHE_LIMIT then
        pron_cache_limit = MIN_PRON_CACHE_LIMIT
    elseif pron_cache_limit > MAX_PRON_CACHE_LIMIT then
        pron_cache_limit = MAX_PRON_CACHE_LIMIT
    end
    env._pron_cache_limit = pron_cache_limit
end

return M
