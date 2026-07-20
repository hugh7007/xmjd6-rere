-- candidate_order_filter.lua
-- Hide original candidates superseded by candidate_order.txt.

local core = require("xmjd6.candidate_order_core")

local function get_store_file(env)
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        local file = env.engine.schema.config:get_string("candidate_order/store_file")
        if file and file ~= "" then return file end
    end
    return core.default_filename
end

local function pass_through(input)
    for cand in input:iter() do
        yield(cand)
    end
end

local function filter(input, env)
    if not core.is_enabled(env) then
        pass_through(input)
        return
    end

    local context = env and env.engine and env.engine.context
    local code = context and context.input or ""
    local file = get_store_file(env)
    local data = core.load(file)

    -- 绝大多数编码没有动态调频规则，直接透传。尤其 bq/te 这类
    -- 候选很多的前缀，避免对每个候选重复做 mtime/索引检查。
    if not core.has_rules_for_input(data, code) then
        pass_through(input)
        return
    end

    for cand in input:iter() do
        if not core.should_hide_loaded(data, code, cand.text, cand.type) then
            yield(cand)
        end
    end
end

return filter
