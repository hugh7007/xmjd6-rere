-- dynamic_phrase_processor.lua
-- Applies '/'' dynamic phrase commands when user confirms with space/enter.
-- Also handles ''' management mode: list phrases, press 0 to delete.

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

local function is_delete_key(key)
    if not key or key:release() or key:ctrl() or key:alt() or key:super() then
        return false
    end
    local repr = key.repr and key:repr() or ""
    return key.keycode == string.byte("'") or repr == "apostrophe"
end

local function management_query(input)
    if type(input) ~= "string" then return nil end
    return input:match("^'''([^';]*)$")
end

local function refresh_context(context)
    if context and type(context.refresh_non_confirmed_composition) == "function" then
        pcall(function() context:refresh_non_confirmed_composition() end)
    end
end

local function selected_manager_entry(context)
    if not context or type(context.get_selected_candidate) ~= "function" then
        return nil
    end
    local ok, cand = pcall(function() return context:get_selected_candidate() end)
    if not ok or not cand or cand.type ~= "dynamic_phrase_manager" then
        return nil
    end
    local text = cand.text or ""
    local comment = cand.comment or ""
    local code = comment:match("^(.-)〔自造·按'删除〕$")
    if text == "" or not code or code == "" then return nil end
    return { text = text, code = code }
end

local function is_management_status_candidate(cand)
    if not cand or not cand.type then return false end
    return cand.type == "dynamic_phrase_manager_empty"
        or cand.type == "dynamic_phrase_manager_notice"
        or cand.type == "dynamic_phrase_delete_confirm"
end

local function cancel_stale_manager_state(context, key_is_delete)
    local input = context and context.input or ""
    local pending = state.pending_delete
    if pending and pending.input ~= input then
        state.pending_delete = nil
        refresh_context(context)
        return key_is_delete
    end
    if pending and not key_is_delete then
        state.pending_delete = nil
        refresh_context(context)
    end
    local notice = state.manager_notice
    if notice and notice.input ~= input then
        state.manager_notice = nil
    elseif notice and not key_is_delete then
        state.manager_notice = nil
    end
    return false
end

local function handle_manager_zero(context, env)
    local input = context and context.input or ""
    if management_query(input) == nil then return kNoop end

    local pending = state.pending_delete
    if pending and pending.input == input then
        local ok, message = core.delete_phrase(
            pending.text,
            pending.code,
            get_store_path(env),
            get_candidate_order_store_path(env)
        )
        state.pending_delete = nil
        state.manager_notice = {
            input = input,
            message = ok and (message or "删除完成")
                or ("删除失败：" .. (message or "无法写入动态词库")),
            ok = ok == true,
        }
        refresh_context(context)
        return kAccepted
    end

    local entry = selected_manager_entry(context)
    if entry then
        state.pending_delete = {
            input = input,
            text = entry.text,
            code = entry.code,
        }
        state.manager_notice = nil
        refresh_context(context)
    end
    -- Always swallow 0 in management mode so it cannot select/commit a helper candidate.
    return kAccepted
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

    local context = env and env.engine and env.engine.context
    if not context then
        return kNoop
    end

    -- Management mode: 0 deletes, other keys cancel stale state.
    local key_is_delete = is_delete_key(key)
    if cancel_stale_manager_state(context, key_is_delete) then
        return kAccepted
    end
    if key_is_delete then
        return handle_manager_zero(context, env)
    end

    local input = context.input or ""
    local in_management = management_query(input) ~= nil

    -- In management mode, swallow ; to prevent command execution.
    -- Space and Return fall through to selector/express_editor so the
    -- highlighted candidate or literal ''' can be committed normally.
    if is_execute_suffix_key(key) and in_management then
        return kAccepted
    end

    if not is_confirm_key(key) then
        return kNoop
    end

    -- Space/Return in management mode: fall through (do not resolve as command)
    if in_management then
        -- Enter on bare ''' commits the literal three-apostrophe string directly,
        -- regardless of which candidate is highlighted. Mirrors the '' apostrophe
        -- behavior: space commits the highlighted candidate (first dynamic phrase),
        -- while Enter commits the symbol ''' itself. Functional sub-states
        -- (delete confirm / notice) keep their current behavior.
        local k = key.keycode
        local repr = key.repr and key:repr() or ""
        local is_return = (k == 0x0d or repr == "Return" or repr == "KP_Enter")
        if is_return and input == "'''" then
            local pd = state.pending_delete
            local mn = state.manager_notice
            if not (pd and pd.input == input) and not (mn and mn.input == input) then
                env.engine:commit_text("'''")
                context:clear()
                return kAccepted
            end
        end
        -- If the highlighted candidate is a status message (empty list, delete
        -- notice, or delete confirm), close the window instead of committing it.
        local ok, selected = pcall(function() return context:get_selected_candidate() end)
        if ok and selected and is_management_status_candidate(selected) then
            context:clear()
            return kAccepted
        end
        return kNoop
    end

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

    -- Explicit pasted command ('词'码) may commit the added word once.
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
