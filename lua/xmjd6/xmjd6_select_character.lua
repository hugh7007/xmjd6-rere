local kAccepted = 1
local kNoop = 2

local function utf8_safe_sub(s, i, j)
    if type(s) ~= "string" or s == "" then return "" end

    i = i or 1
    j = j or -1

    local len = utf8.len(s)
    if not len or len == 0 then return "" end

    if i < 0 then i = math.max(len + 1 + i, 1) else i = math.min(i, len) end
    if j < 0 then j = math.max(len + 1 + j, 1) else j = math.min(j, len) end
    if j < i then return "" end

    local byte_start = utf8.offset(s, i)
    if not byte_start then return "" end
    local byte_end = utf8.offset(s, j + 1)
    return byte_end and s:sub(byte_start, byte_end - 1) or s:sub(byte_start)
end

local function commit_slice(engine, context, text, i, j)
    local slice = utf8_safe_sub(text, i, j)
    if slice ~= "" then
        engine:commit_text(slice)
        context:clear()
        return kAccepted
    end
    return kNoop
end

local select_character = {}

function select_character.init(env)
    local config = env.engine.schema.config
    env.first_key = config:get_string('key_binder/select_first_character')
    env.last_key = config:get_string('key_binder/select_last_character')
end

function select_character.func(key, env)
    if key:release() then return kNoop end
    local first_key, last_key = env.first_key, env.last_key
    if not (first_key or last_key) then return kNoop end

    local engine = env.engine
    local context = engine.context
    if not (context:is_composing() or context:has_menu()) then
        return kNoop
    end

    local key_repr = key:repr()
    if key_repr ~= first_key and key_repr ~= last_key then
        return kNoop
    end

    local text
    local selected = context:get_selected_candidate()
    if selected and selected.text and selected.text ~= "" then
        text = selected.text
    else
        text = context.input
    end

    if not text or utf8.len(text) == nil or utf8.len(text) <= 1 then
        return kNoop
    end

    if first_key and key_repr == first_key then
        return commit_slice(engine, context, text, 1, 1)
    end
    if last_key and key_repr == last_key then
        return commit_slice(engine, context, text, -1, -1)
    end
    return kNoop
end

function select_character.fini(env)
    env.first_key = nil
    env.last_key = nil
end

return select_character
