-- 补全候选过滤器
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-05
local utf8_len = utf8.len
local type = type

local function is_reverse_lookup_context(ctx)
    if not ctx then
        return false
    end
    local input = ctx.input or ""
    if input:find("`", 1, true) or input:match("^[vo]") then
        return true
    end
    local seg = ctx.composition and ctx.composition:back()
    if not seg then
        return false
    end
    if seg.has_tag then
        local ok, has_tag = pcall(function()
            return seg:has_tag("reverse_lookup") or seg:has_tag("jderfen") or seg:has_tag("gbk")
        end)
        if ok and has_tag then
            return true
        end
    end
    return seg.tag == "reverse_lookup" or seg.tag == "jderfen" or seg.tag == "gbk"
end

return {
    init = function(env)
        local config = env.engine.schema.config
        env._danzi_first = not (config:get_bool("translator/enable_sentence") or false)
    end,

    func = function(input, env)
        local ctx = env.engine and env.engine.context
        local enabled = ctx and ctx:get_option("completion") or false
        local danzi = env._danzi_first
        local reverse_lookup = is_reverse_lookup_context(ctx)
        local buffer = {}
        local buffer_size = 0
        local comp_count = 0

        for cand in input:iter() do
            if cand.type == "completion" then
                if reverse_lookup then
                    goto continue
                end
                if not enabled then break end
                comp_count = comp_count + 1
                if comp_count > 30 then break end
            end
            if not danzi then
                yield(cand)
            else
                local c = cand.comment
                if c and type(c) == "string" and #c == 0 then
                    yield(cand)
                else
                    local text_len = utf8_len(cand.text)
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
    end,

    fini = function(env)
        env._danzi_first = nil
    end
}
