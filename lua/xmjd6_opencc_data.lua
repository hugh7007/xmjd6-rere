-- OpenCC 数据加载工具
-- 管理 opencc/Data Lua 表、短语分片缓存和 dataset 生命周期。
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-05-29

local M = {}

local PHRASE_SHARD_CACHE_LIMIT = 16

local insert = table.insert
local remove = table.remove
local s_match = string.match
local s_gmatch = string.gmatch
local s_sub = string.sub
local s_gsub = string.gsub
local s_byte = string.byte
local open = io.open
local type = type
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local dofile = dofile

local shared_static = {
    datasets = {},
    phrase_shards = {},
    phrase_usage = {},
    path_cache = {},
    project_dirs = nil,
    base_dir = nil,
    schema_id = nil,
}

local function clear_table(t)
    for i = 1, #t do
        t[i] = nil
    end
end

local function clear_map(t)
    for k, _ in pairs(t) do
        t[k] = nil
    end
end

local function dirname(path)
    return s_match(path or "", "^(.*[/\\])") or ""
end

local function join_path(base, relative)
    if not base or base == "" then
        return relative
    end
    return base .. "/" .. relative
end

local function trim_trailing_sep(path)
    return s_gsub(path or "", "[/\\]+$", "")
end

local function push_unique_candidate(candidates, seen, path)
    if path and path ~= "" and not seen[path] then
        seen[path] = true
        insert(candidates, path)
    end
end

local function collect_project_dirs()
    if shared_static.project_dirs then
        return shared_static.project_dirs
    end

    local dirs = {}
    local seen = {}

    local function push(path)
        path = trim_trailing_sep(path)
        if path ~= "" and not seen[path] then
            seen[path] = true
            insert(dirs, path)
        end
    end

    local lua_dir = shared_static.base_dir or ""
    local project_dir = lua_dir ~= "" and dirname(s_sub(lua_dir, 1, -2)) or ""
    if project_dir ~= "" then
        push(project_dir)
    elseif lua_dir ~= "" then
        push(".")
    end

    local api = rime_api
    if api and api.get_user_data_dir then
        local ok, user_dir = pcall(api.get_user_data_dir)
        if ok and type(user_dir) == "string" and user_dir ~= "" then
            push(user_dir)
        end
    end

    local schema_id = shared_static.schema_id or ""
    local pkg_path = package and package.path or nil
    if type(pkg_path) == "string" and pkg_path ~= "" and schema_id ~= "" then
        local marker = "/" .. schema_id .. "/"
        for entry in s_gmatch(pkg_path, "[^;]+") do
            local prefix = s_match(entry, "^(.*)%?")
            if prefix and prefix ~= "" then
                prefix = trim_trailing_sep(s_gsub(prefix, "\\", "/"))
                local prefixed = prefix .. "/"
                local at = string.find(prefixed, marker, 1, true)
                if at then
                    push(s_sub(prefixed, 1, at + #marker - 2))
                elseif s_match(prefix, "/lua$") then
                    local parent = s_sub(prefix, 1, -5)
                    if parent == "" then
                        push(".")
                        push(schema_id)
                    else
                        push(parent)
                        push(join_path(parent, schema_id))
                    end
                end
            end
        end
    end

    if schema_id ~= "" then
        push(schema_id)
        local user_dir = nil
        if api and api.get_user_data_dir then
            local ok, value = pcall(api.get_user_data_dir)
            if ok and type(value) == "string" and value ~= "" then
                user_dir = value
            end
        end
        if user_dir then
            push(join_path(user_dir, schema_id))
        end
    end

    shared_static.project_dirs = dirs
    return dirs
end

local function build_project_candidates(relative)
    local candidates = {}
    local seen = {}
    if not relative or relative == "" then
        return candidates
    end

    for _, project_dir in ipairs(collect_project_dirs()) do
        push_unique_candidate(candidates, seen, join_path(project_dir, relative))
    end

    return candidates
end

local function find_existing_path(candidates)
    local tried = {}
    for _, path in ipairs(candidates) do
        if path and path ~= "" and not tried[path] then
            tried[path] = true
            local f = open(path, "r")
            if f then
                f:close()
                return path
            end
        end
    end
    return nil
end

local function load_lua_table(relative_path)
    if relative_path == "" then
        return nil
    end
    local path = shared_static.path_cache[relative_path]
    if path == false then
        return nil
    end
    if path == nil then
        path = find_existing_path(build_project_candidates("opencc/Data/" .. relative_path))
        shared_static.path_cache[relative_path] = path or false
    end
    if not path then
        return nil
    end
    local ok, mod = pcall(dofile, path)
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function utf8_first_char(text)
    local b = s_byte(text or "", 1)
    if not b then
        return nil
    end
    local len = 1
    if b >= 240 then
        len = 4
    elseif b >= 224 then
        len = 3
    elseif b >= 192 then
        len = 2
    end
    return s_sub(text, 1, len)
end

local function touch_phrase_shard(module_name)
    local usage = shared_static.phrase_usage
    for i = #usage, 1, -1 do
        if usage[i] == module_name then
            remove(usage, i)
            break
        end
    end
    insert(usage, module_name)
    while #usage > PHRASE_SHARD_CACHE_LIMIT do
        local expired = remove(usage, 1)
        if expired and expired ~= module_name then
            shared_static.phrase_shards[expired] = nil
            pcall(function()
                if package and package.loaded then
                    package.loaded[expired] = nil
                end
            end)
        end
    end
end

local function clear_dataset_phrase_shards(dataset)
    if not dataset or not dataset.name then
        return
    end
    local prefix = dataset.name .. "_phrases_"
    for module_name, _ in pairs(shared_static.phrase_shards) do
        if s_match(module_name, "^" .. prefix) then
            shared_static.phrase_shards[module_name] = nil
        end
    end
    local usage = shared_static.phrase_usage
    local i = 1
    while i <= #usage do
        if s_match(usage[i], "^" .. prefix) then
            remove(usage, i)
        else
            i = i + 1
        end
    end
end

local function release_dataset(dataset_name)
    local dataset = shared_static.datasets[dataset_name]
    if not dataset then
        return false
    end
    clear_dataset_phrase_shards(dataset)
    shared_static.datasets[dataset_name] = nil
    return true
end

local function ensure_dataset_loaded(dataset_name)
    if not dataset_name or dataset_name == "" then
        return nil
    end
    local dataset = shared_static.datasets[dataset_name]
    if dataset then
        if not dataset.chars then
            dataset.chars = load_lua_table(dataset.name .. "_chars.lua") or {}
        end
        if not dataset.index then
            dataset.index = load_lua_table(dataset.name .. "_phrases_index.lua") or {}
        end
        return dataset
    end

    dataset = {
        name = dataset_name,
        chars = load_lua_table(dataset_name .. "_chars.lua") or {},
        index = load_lua_table(dataset_name .. "_phrases_index.lua") or {},
    }
    shared_static.datasets[dataset_name] = dataset
    return dataset
end

local function get_dataset_phrase_shard(dataset, text)
    if not dataset then
        return nil
    end
    local first = utf8_first_char(text)
    if not first then
        return nil
    end
    local bucket = dataset.index[first]
    if not bucket then
        return nil
    end
    local module_name = dataset.name .. "_phrases_" .. bucket .. ".lua"
    local shard = shared_static.phrase_shards[module_name]
    if not shard then
        shard = load_lua_table(module_name)
        if not shard then
            return nil
        end
        shared_static.phrase_shards[module_name] = shard
    end
    touch_phrase_shard(module_name)
    return shard
end

local function normalize_mapping_value(value, value_mode)
    if not value or value == "" then
        return nil
    end
    value = s_match(value, "^%s*(.-)%s*$") or value
    if value == "" then
        return nil
    end
    if value_mode == "first" then
        return s_match(value, "^%S+") or value
    end
    return value
end

function M.set_context(base_dir, schema_id)
    if shared_static.base_dir ~= base_dir or shared_static.schema_id ~= schema_id then
        shared_static.project_dirs = nil
        clear_map(shared_static.path_cache)
    end
    shared_static.base_dir = base_dir
    shared_static.schema_id = schema_id
end

function M.create_provider(dataset_name, value_mode)
    return {
        dataset_name = dataset_name,
        value_mode = value_mode,
        fetch = function(self, text)
            if not text or text == "" then
                return nil
            end
            local dataset = ensure_dataset_loaded(self.dataset_name)
            if not dataset then
                return nil
            end
            local shard = get_dataset_phrase_shard(dataset, text)
            if shard then
                local phrase_val = normalize_mapping_value(shard[text], self.value_mode)
                if phrase_val and phrase_val ~= "" then
                    return phrase_val
                end
            end
            return normalize_mapping_value(dataset.chars[text], self.value_mode)
        end,
        release = function(self)
            release_dataset(self.dataset_name)
        end,
    }
end

function M.release_inactive(active_datasets)
    local released = false
    for dataset_name, _ in pairs(shared_static.datasets) do
        if not active_datasets or not active_datasets[dataset_name] then
            if release_dataset(dataset_name) then
                released = true
            end
        end
    end
    return released
end

function M.release_all()
    clear_map(shared_static.datasets)
    clear_map(shared_static.phrase_shards)
    clear_table(shared_static.phrase_usage)
end

return M
