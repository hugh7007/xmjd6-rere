-- dynamic_phrase_processor.lua
-- Applies '/'' dynamic phrase commands when user confirms with space/enter.

local core = require("xmjd6.dynamic_phrase_core")

local kAccepted = 1
local kNoop = 2

_G.__dynamic_phrase_state = _G.__dynamic_phrase_state or {}
local state = _G.__dynamic_phrase_state

local function get_store_path(env)
    local file = nil
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        file = env.engine.schema.config:get_string("dynamic_phrase/store_file")
    end
    return core.store_path(file or core.default_filename)
end

local function get_candidate_order_store_path(env)
    local file = nil
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        file = env.engine.schema.config:get_string("candidate_order/store_file")
    end
    return core.store_path(file or "candidate_order.txt")
end

local function key_to_char(key)
    local ch = key and key.keycode
    if not ch or ch < 0x20 or ch >= 0x7f then
        return nil
    end
    return string.char(ch)
end

local function is_execute_suffix_key(key)
    if key_to_char(key) == ";" then
        return true
    end
    local repr = key and key.repr and key:repr() or ""
    return repr == "semicolon"
end

local function is_confirm_key(key)
    if not key then return false end
    if is_execute_suffix_key(key) then
        return true
    end
    if key.keycode == 0x20 or key.keycode == 0x0d or key.keycode == 0x0a then
        return true
    end
    local repr = key.repr and key:repr() or ""
    return repr == "space" or repr == "Return" or repr == "KP_Enter" or repr == "semicolon"
end

local function get_commit_history()
    return state.commit_history or (state.last_commit_text and { state.last_commit_text }) or {}
end

local function remember_commit_text(committed)
    if type(committed) ~= "string" or committed == "" then
        return
    end
    -- Do not let helper/status text replace the user's real phrase history.
    if committed:match("^已添加") or committed:match("^已删除") or committed:match("^未找到") then
        return
    end

    state.last_commit_text = committed
    state.commit_history = state.commit_history or {}
    state.commit_history[#state.commit_history + 1] = committed
    while #state.commit_history > 8 do
        table.remove(state.commit_history, 1)
    end
end

local function processor(key, env)
    if not key or key:release() or key:ctrl() or key:alt() or key:super() then
        return kNoop
    end
    if not is_confirm_key(key) then
        return kNoop
    end

    local context = env and env.engine and env.engine.context
    if not context then
        return kNoop
    end

    local input = context.input or ""
    local command_input = input
    if is_execute_suffix_key(key) then
        command_input = input .. ";"
    end
    if not core.is_dynamic_command(command_input) then
        return kNoop
    end

    local cmd = core.resolve_command(command_input, get_commit_history())
    if not cmd then
        -- If the input is just bare apostrophes (' or '') and user presses
        -- space/enter (not ;), let the event fall through to selector /
        -- express_editor so that:
        --   - with candidates: space/enter commits the highlighted candidate
        --   - without candidates: space/enter commits the literal input
        if not is_execute_suffix_key(key) and (input == "'" or input == "''") then
            return kNoop
        end
        -- Keep the composition editable, but swallow confirm so usage candidates are not committed.
        return kAccepted
    end

    local ok = core.apply_resolved_command(cmd, get_store_path(env), get_candidate_order_store_path(env))
    if not ok then
        -- Keep the command in place if saving failed.
        return kAccepted
    end

    -- Explicit pasted command ('词/码) may commit the added word once.
    -- Shorthand ('码) uses the word that is already on screen, so do not duplicate it.
    if cmd.action == "add" and not cmd.from_last_commit and cmd.text and cmd.text ~= "" then
        env.engine:commit_text(cmd.text)
    end
    context:clear()
    return kAccepted
end

local function init(env)
    local context = env and env.engine and env.engine.context
    if not context or not context.commit_notifier then
        return
    end

    env.dynamic_phrase_commit_connection = context.commit_notifier:connect(function(ctx)
        local ok, committed = pcall(function() return ctx:get_commit_text() end)
        if ok then
            remember_commit_text(committed)
        end
    end)
end

local function fini(env)
    if env and env.dynamic_phrase_commit_connection then
        pcall(function() env.dynamic_phrase_commit_connection:disconnect() end)
        env.dynamic_phrase_commit_connection = nil
    end
end

return { init = init, func = processor, fini = fini }
