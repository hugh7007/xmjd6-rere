-- repeat_history.lua
-- Cross-context repeat-history candidates backed by the global commit history
-- maintained by dynamic_phrase_processor.lua.

local M = {}

local DEFAULT_INPUT = "i"
local DEFAULT_SIZE = 3

local function get_config_string(env, key, default)
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    if config and config.get_string then
        local ok, value = pcall(function() return config:get_string(key) end)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return default
end

local function get_config_int(env, key, default)
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    if config and config.get_int then
        local ok, value = pcall(function() return config:get_int(key) end)
        if ok and type(value) == "number" and value > 0 then
            return math.floor(value)
        end
    end
    return default
end

local function history()
    local state = _G.__dynamic_phrase_state or {}
    local source = state.commit_history
    if type(source) == "table" then
        return source
    end
    if type(state.last_commit_text) == "string" and state.last_commit_text ~= "" then
        return { state.last_commit_text }
    end
    return {}
end

local function make_candidate(seg, text, comment, quality)
    local cand = Candidate("repeat_history", seg and seg.start or 0, seg and seg._end or #text, text, comment or "")
    cand.quality = quality or 10000
    return cand
end

local function translator(input, seg, env)
    local trigger = get_config_string(env, "repeat_history/input", DEFAULT_INPUT)
    if input ~= trigger then
        return
    end

    local size = get_config_int(env, "repeat_history/size", DEFAULT_SIZE)
    local items = history()
    local yielded = 0
    local seen = {}
    for i = #items, 1, -1 do
        local text = tostring(items[i] or "")
        if text ~= "" and not seen[text] then
            yielded = yielded + 1
            seen[text] = true
            yield(make_candidate(seg, text, "历史" .. yielded, 10000 - yielded))
            if yielded >= size then
                return
            end
        end
    end
end

M.func = translator

return M
