-- 补全候选过滤器
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-29

local config_util = require("xmjd6_config")
local candidate_util = require("xmjd6_candidate")

local type = type
local COMPLETION_LIMIT = 30
local COMPLETION_MAX_CODE_LEN = 5

local function is_reverse_lookup_context(ctx, env)
    return config_util.is_reverse_context(ctx, env and env._reverse_tags, env and env._reverse_prefixes)
end

return {
    init = function(env)
        local config = env.engine.schema.config
        env._danzi_first = not (config:get_bool("translator/enable_sentence") or false)
        env._reverse_tags, env._reverse_prefixes = config_util.collect_reverse_context(
            config,
            env.engine.schema.schema_id or "",
            false
        )
    end,

    func = function(input, env)
        local ctx = env.engine and env.engine.context
        local input_text = ctx and ctx.input or ""
        local input_len = #input_text
        local enabled = ctx and ctx:get_option("completion") or false
        local allow_completion = enabled and input_len <= COMPLETION_MAX_CODE_LEN
        local danzi = env._danzi_first
        local reverse_lookup = nil
        local buffer = {}
        local buffer_size = 0
        local completion_buffer = {}
        local completion_buffer_size = 0
        local comp_count = 0

        for cand in input:iter() do
            if cand.type == "completion" then
                if reverse_lookup == nil then
                    reverse_lookup = is_reverse_lookup_context(ctx, env)
                end
                if reverse_lookup then
                    break
                end
                if not allow_completion then break end
                if comp_count >= COMPLETION_LIMIT then break end
                comp_count = comp_count + 1
                completion_buffer_size = completion_buffer_size + 1
                completion_buffer[completion_buffer_size] = cand
                goto continue
            end
            if not danzi then
                yield(cand)
            else
                local c = cand.comment
                if c and type(c) == "string" and #c == 0 then
                    yield(cand)
                else
                    local text_len = candidate_util.utf8_len(cand.text)
                    if text_len == 1 then
                        yield(cand)
                    elseif text_len and text_len > 1 then
                        buffer_size = buffer_size + 1
                        buffer[buffer_size] = cand
                    end
                end
            end
            ::continue::
        end

        for i = 1, buffer_size do
            yield(buffer[i])
        end
        for i = 1, completion_buffer_size do
            yield(completion_buffer[i])
        end
    end,

    fini = function(env)
        env._danzi_first = nil
        env._reverse_tags = nil
        env._reverse_prefixes = nil
    end
}
