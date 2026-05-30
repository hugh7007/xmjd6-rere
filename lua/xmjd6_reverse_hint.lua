-- 万能符反查读音补全
-- 只在 reverse_lookup 模式下运行，把当前方案 cx 字典中的单字读音拼入注释。
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-29

local config_util = require("xmjd6_config")
local candidate_util = require("xmjd6_candidate")
local reverse = require("xmjd6_reverse")

local M = {}

local function is_reverse_lookup(env)
    local ctx = env.engine.context
    local seg = ctx and ctx.composition and ctx.composition:back()
    return config_util.segment_has_tag(seg, "reverse_lookup")
end

local function release_pron_cache()
    reverse.clear_pron_cache()
    collectgarbage("step", 48)
end

function M.func(input, env)
    local reverse_mode = is_reverse_lookup(env)
    if not reverse_mode then
        if env._reverse_hint_active then
            env._reverse_hint_active = false
            release_pron_cache()
        end
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    env._reverse_hint_active = true
    for cand in input:iter() do
        if candidate_util.utf8_len(cand.text) == 1 then
            local p = reverse.lookup_pron(env._cx_dict, cand.text, env._pron_cache_limit)
            if p then
                candidate_util.set_comment(cand, candidate_util.merge_pron_comment(p, cand.comment))
            end
        end
        yield(cand)
    end
end

function M.fini(env)
    release_pron_cache()
    if env._reverse_shared_acquired then
        reverse.release()
        env._reverse_shared_acquired = nil
    end
    env._reverse_hint_active = nil
    env._cx_dict = nil
    env._pron_cache_limit = nil
end

function M.init(env)
    if not env._reverse_shared_acquired then
        reverse.acquire()
        env._reverse_shared_acquired = true
    end
    reverse.reset_failed()
    env._reverse_hint_active = false

    local config = env.engine.schema.config
    env._cx_dict = config_util.resolve_pron_dict(config, env.engine.schema.schema_id or "")
    env._pron_cache_limit = reverse.cache_limit(config, "pron_cache_limit")
end

return M
