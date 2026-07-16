-- 天行键直出符号候选与码表缓存
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-10

local string_byte = string.byte
local string_sub = string.sub
local type = type
local key_event_util = require("xmjd6_key_event")
local commit_guard = require("xmjd6_commit_guard")

local M = {}
local kAccepted = 1
local kNoop = 2
local CHAR_CACHE = key_event_util.char_cache
local symbol_code_state

local function trim_trailing_sep(path)
    return (path or ""):gsub("[/\\]+$", "")
end

local function dirname(path)
    return (path or ""):match("^(.*)[/\\][^/\\]*$") or ""
end

local function join_path(base, name)
    if not base or base == "" then return name end
    return base .. "/" .. name
end

local function module_project_dir()
    local info = debug and debug.getinfo and debug.getinfo(1, "S") or nil
    local source = info and info.source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    source = source:gsub("\\", "/")
    local lua_dir = dirname(source)
    if lua_dir:match("/lua$") or lua_dir == "lua" then return dirname(lua_dir) end
    return lua_dir
end

local function push_unique_path(list, seen, path)
    path = trim_trailing_sep(path)
    if path ~= "" and not seen[path] then
        seen[path] = true
        list[#list + 1] = path
    end
end

local function core_dict_candidates(schema_id)
    local file_name = ((schema_id and schema_id ~= "") and schema_id or "xmjd6") .. ".core.dict.yaml"
    local candidates, seen = {}, {}
    push_unique_path(candidates, seen, file_name)
    push_unique_path(candidates, seen, join_path(module_project_dir(), file_name))
    local api = rime_api
    if api and api.get_user_data_dir then
        local ok, user_dir = pcall(api.get_user_data_dir)
        if ok and type(user_dir) == "string" and user_dir ~= "" then
            push_unique_path(candidates, seen, join_path(user_dir, file_name))
        end
    end
    return candidates
end

local function find_existing_path(candidates)
    for _, path in ipairs(candidates or {}) do
        local file = io.open(path, "r")
        if file then file:close(); return path end
    end
    return nil
end

local function load_symbol_code_state(schema_id)
    local path = find_existing_path(core_dict_candidates(schema_id))
    local state = { codes = {}, prefixes = {}, max_len = 0 }
    if not path then return state end
    local file = io.open(path, "r")
    if not file then return state end
    local in_region = false
    for line in file:lines() do
        if line:match("^%s*#region%s+<快符>%s*$") then
            in_region = true
        elseif line:match("^%s*#endregion%s+<快符>%s*$") then
            break
        elseif in_region and not line:match("^%s*#") then
            local code = line:match("^[^\t]+\t(;%S+)")
            if code then code = string_sub(code, 2) end
            if code and code ~= "" then
                state.codes[code] = true
                if #code > state.max_len then state.max_len = #code end
                for i = 1, #code - 1 do state.prefixes[string_sub(code, 1, i)] = true end
            end
        end
    end
    file:close()
    return state
end

local function code_state(schema_id)
    if not symbol_code_state then symbol_code_state = load_symbol_code_state(schema_id) end
    return symbol_code_state
end

function M.reset_cache()
    symbol_code_state = nil
end

function M.is_input(input)
    return type(input) == "string" and #input > 1 and string_byte(input, 1) == 59
end

local function completion_is_candidate(env, ctx)
    if env._direct_symbols_fast_leaf then return false end
    return ctx and ctx:get_option("completion") or false
end

function M.is_candidate(env, ctx, cand)
    if not cand then return false end
    if not commit_guard.is_completion_candidate(cand) then return true end
    return completion_is_candidate(env, ctx)
end

function M.has_candidate(env, ctx)
    local selected = ctx:get_selected_candidate()
    if selected then return M.is_candidate(env, ctx, selected) end
    local comp = ctx.composition and ctx.composition:back()
    local menu = comp and comp.menu
    if not menu then return false end
    local ok, cand = pcall(function() return menu:get_candidate_at(0) end)
    return ok and M.is_candidate(env, ctx, cand) or false
end

function M.first_candidate(env, ctx)
    local comp = ctx and ctx.composition and ctx.composition:back()
    local menu = comp and comp.menu
    if not menu then return nil end
    local index = 0
    while true do
        local ok, cand = pcall(function() return menu:get_candidate_at(index) end)
        if not ok or not cand then break end
        if M.is_candidate(env, ctx, cand) then return cand end
        index = index + 1
    end
    return nil
end

function M.commit_first(env, ctx, engine)
    local first = M.first_candidate(env, ctx)
    if not first then return false end
    local selected = commit_guard.selected_candidate(ctx)
    if selected and M.is_candidate(env, ctx, selected) then ctx:commit(); return true end
    if not engine then return false end
    ctx:clear()
    engine:commit_text(first.text)
    return true
end

function M.has_real_successor(env, ctx, input)
    input = input or (ctx and ctx.input) or ""
    if not M.is_input(input) then return false end
    if env._direct_symbols_fast_leaf then
        for i = 97, 122 do
            local char = CHAR_CACHE[i]
            ctx:push_input(char)
            local pushed_input = ctx.input or ""
            local has_successor = #pushed_input > #input and string_sub(pushed_input, 1, #input) == input
                and commit_guard.has_non_completion_candidate(ctx)
            if #pushed_input > #input and string_sub(pushed_input, 1, #input) == input then ctx:pop_input(1) end
            if (ctx.input or "") ~= input then return false end
            if has_successor then return true end
        end
        return false
    end
    local code = string_sub(input, 2)
    return code_state(env.schema_id).prefixes[code] == true
end

function M.known_path(env, input)
    if not M.is_input(input) or env._direct_symbols_fast_leaf then return false end
    local code = string_sub(input, 2)
    local state = code_state(env.schema_id)
    return state.codes[code] == true or state.prefixes[code] == true
end

function M.commit_unique_if_leaf(env, ctx, engine)
    local input = ctx and ctx.input or ""
    if not M.is_input(input) or not M.first_candidate(env, ctx) then return false end
    if M.has_real_successor(env, ctx, input) then return false end
    return M.commit_first(env, ctx, engine)
end

function M.handle_alpha_press(env, ctx, key, opts)
    if env._tu_streaming or not opts.direct_symbols or not env._alpha[key] then return false end
    local current_input = ctx.input or ""
    if not M.is_input(current_input) then return false end
    local current_candidate = M.first_candidate(env, ctx)
    if not M.has_candidate(env, ctx) and not M.known_path(env, current_input) then return false end
    commit_guard.clear_space(env)
    ctx:push_input(key)
    local pushed_input = ctx.input or ""
    if #pushed_input > #current_input and string_sub(pushed_input, 1, #current_input) == current_input then
        if M.has_candidate(env, ctx) then
            commit_guard.note_space(env, ctx, current_input, key)
            if M.commit_unique_if_leaf(env, ctx, env.engine) then return kAccepted end
            return kAccepted
        end
        if M.known_path(env, pushed_input) then
            commit_guard.note_space(env, ctx, current_input, key)
            return kAccepted
        end
        ctx:pop_input(1)
        if (ctx.input or "") ~= current_input then return kAccepted end
        if not current_candidate or not M.commit_first(env, ctx, env.engine) then return false end
        commit_guard.note_space(env, ctx, "", key)
        return kNoop
    end
    return kAccepted
end

return M
