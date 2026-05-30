-- 反查缓存工具
-- 统一管理 ReverseLookup 句柄、读音缓存和释放策略。
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-29

local M = {}

local DEFAULT_CACHE_LIMIT = 256
local MIN_CACHE_LIMIT = 64
local MAX_CACHE_LIMIT = 512

local handles = {}
local pron_cache = {}
local pron_cache_count = 0
local hint_cache = {}
local hint_cache_count = 0
local core_hint_maps = {}
local active_envs = 0

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

local function push_unique(list, seen, path)
    path = trim_trailing_sep(path)
    if path ~= "" and not seen[path] then
        seen[path] = true
        list[#list + 1] = path
    end
end

local function module_project_dir()
    local info = debug and debug.getinfo and debug.getinfo(1, "S") or nil
    local source = info and info.source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    source = source:gsub("\\", "/")
    local lua_dir = dirname(source)
    if lua_dir:match("/lua$") or lua_dir == "lua" then
        return dirname(lua_dir)
    end
    return lua_dir
end

local function package_project_dirs(stem)
    local dirs, seen = {}, {}
    local path = package and package.path or ""
    for entry in path:gmatch("[^;]+") do
        local prefix = entry:match("^(.*)%?")
        if prefix then
            prefix = trim_trailing_sep(prefix:gsub("\\", "/"))
            if prefix:match("/lua$") or prefix == "lua" then
                push_unique(dirs, seen, dirname(prefix))
            elseif stem and stem ~= "" and (prefix:match("/" .. stem .. "$") or prefix == stem) then
                push_unique(dirs, seen, prefix)
            end
        end
    end
    return dirs
end

local function core_dict_candidates(dict_name)
    local file_name = dict_name .. ".dict.yaml"
    local stem = dict_name:match("^(.+)%.core$")
    local candidates, seen = {}, {}

    push_unique(candidates, seen, file_name)
    push_unique(candidates, seen, join_path(module_project_dir(), file_name))

    for _, dir in ipairs(package_project_dirs(stem)) do
        push_unique(candidates, seen, join_path(dir, file_name))
    end

    local api = rime_api
    if api and api.get_user_data_dir then
        local ok, user_dir = pcall(api.get_user_data_dir)
        if ok and type(user_dir) == "string" and user_dir ~= "" then
            push_unique(candidates, seen, join_path(user_dir, file_name))
            if stem and stem ~= "" then
                push_unique(candidates, seen, join_path(join_path(user_dir, stem), file_name))
            end
        end
    end

    return candidates
end

local function find_existing_path(candidates)
    for _, path in ipairs(candidates or {}) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

local function parse_core_hint_dict(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local map = {}
    local in_body = false
    for line in f:lines() do
        if not in_body then
            if line:match("^%.%.%.%s*$") then
                in_body = true
            end
        elseif line ~= "" and not line:match("^%s*#") and not line:match("^%s*---") then
            local text, code = line:match("^([^\t]+)\t([^%s#]+)")
            if text and code and text ~= "" and code ~= "" then
                local existing = map[text]
                map[text] = existing and (existing .. " " .. code) or code
            end
        end
    end
    f:close()

    if next(map) then return map end
    return nil
end

local function close_entry(dict_name)
    local entry = dict_name and handles[dict_name]
    if not entry then return end
    if entry.handle and entry.handle.close then
        pcall(function() entry.handle:close() end)
    end
    handles[dict_name] = nil
end

local function open_handle(dict_name)
    if not dict_name or dict_name == "" then return nil end
    local entry = handles[dict_name]
    if entry then
        if entry.handle then return entry.handle end
        if entry.failed then return nil end
    end

    local ok, handle = pcall(ReverseLookup, dict_name)
    if ok and handle then
        handles[dict_name] = { handle = handle, failed = false }
        return handle
    end
    handles[dict_name] = { failed = true }
    return nil
end

local function cache_key(dict_name, text)
    return (dict_name or "") .. "\0" .. (text or "")
end

local function clear_pron_cache()
    pron_cache = {}
    pron_cache_count = 0
end

local function clear_hint_cache()
    hint_cache = {}
    hint_cache_count = 0
end

local function clear_core_hint_maps()
    core_hint_maps = {}
end

local function load_core_hint_map(dict_name)
    if not dict_name or dict_name == "" then return nil, false end

    local cached = core_hint_maps[dict_name]
    if cached ~= nil then
        if cached == false then return nil, false end
        return cached, true
    end

    local path = find_existing_path(core_dict_candidates(dict_name))
    if not path then
        core_hint_maps[dict_name] = false
        return nil, false
    end

    local map = parse_core_hint_dict(path)
    core_hint_maps[dict_name] = map or false
    return map, map ~= nil
end

function M.acquire()
    active_envs = active_envs + 1
end

function M.release()
    if active_envs > 0 then active_envs = active_envs - 1 end
    if active_envs == 0 then
        for dict_name in pairs(handles) do
            close_entry(dict_name)
        end
        clear_pron_cache()
        clear_hint_cache()
        clear_core_hint_maps()
        collectgarbage("step", 64)
    end
end

function M.reset_failed(dict_name)
    if dict_name then
        local entry = handles[dict_name]
        if entry and entry.failed then handles[dict_name] = nil end
        return
    end
    for name, entry in pairs(handles) do
        if entry and entry.failed then handles[name] = nil end
    end
end

function M.close(dict_name)
    close_entry(dict_name)
end

function M.lookup(dict_name, text)
    local handle = open_handle(dict_name)
    if not handle then return nil end
    local ok, result = pcall(function()
        return handle:lookup(text)
    end)
    if ok and result and result ~= "" then return result end
    return nil
end

function M.lookup_pron(dict_name, text, limit)
    if not text or utf8.len(text) ~= 1 then return nil end
    local key = cache_key(dict_name, text)
    local cached = pron_cache[key]
    if cached ~= nil then return cached or nil end

    local result = M.lookup(dict_name, text)
    local pron = result and result:match("%(([^%)]+)%)") or nil

    limit = limit or DEFAULT_CACHE_LIMIT
    if pron_cache_count >= limit then clear_pron_cache() end
    pron_cache[key] = pron or false
    pron_cache_count = pron_cache_count + 1
    return pron
end

function M.lookup_hint(dict_name, text, limit)
    if not dict_name or not text or text == "" then return nil end
    local key = cache_key(dict_name, text)
    local cached = hint_cache[key]
    if cached ~= nil then return cached or nil end

    local result = M.lookup(dict_name, text)
    limit = limit or DEFAULT_CACHE_LIMIT
    if hint_cache_count >= limit then clear_hint_cache() end
    hint_cache[key] = result or false
    hint_cache_count = hint_cache_count + 1
    return result
end

function M.lookup_core_hint(dict_names, text)
    if not text or text == "" then return nil, false end
    if type(dict_names) == "string" then dict_names = { dict_names } end

    local checked = false
    for _, dict_name in ipairs(dict_names or {}) do
        local map, available = load_core_hint_map(dict_name)
        if available then
            checked = true
            local result = map[text]
            if result and result ~= "" then
                return result, true
            end
        end
    end
    return nil, checked
end

function M.open_first(dict_names)
    for _, dict_name in ipairs(dict_names or {}) do
        if open_handle(dict_name) then return dict_name end
    end
    return nil
end

function M.cache_limit(config, path)
    local value = config and config:get_int(path)
    value = value or DEFAULT_CACHE_LIMIT
    if value < MIN_CACHE_LIMIT then return MIN_CACHE_LIMIT end
    if value > MAX_CACHE_LIMIT then return MAX_CACHE_LIMIT end
    return value
end

function M.clear_pron_cache()
    clear_pron_cache()
end

function M.clear_hint_cache()
    clear_hint_cache()
end

return M
