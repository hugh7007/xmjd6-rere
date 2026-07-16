-- 万能符反查读音补全
-- 只在 reverse_lookup 模式下运行，把当前方案 cx 字典中的单字读音拼入注释。
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-05-29

local config_util = require("common.xmjd6_config")
local candidate_util = require("common.xmjd6_candidate")
local reverse = require("common.xmjd6_reverse")

local M = {}
local pron_maps = {}

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
    if lua_dir:match("/lua$") or lua_dir == "lua" then
        return dirname(lua_dir)
    end
    return lua_dir
end

local function find_existing_path(file_name)
    local candidates = {
        file_name,
        join_path(module_project_dir(), file_name),
    }
    local api = rime_api
    if api and api.get_user_data_dir then
        local ok, user_dir = pcall(api.get_user_data_dir)
        if ok and type(user_dir) == "string" and user_dir ~= "" then
            candidates[#candidates + 1] = join_path(user_dir, file_name)
        end
    end
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

local function merge_pron(old, new)
    if not old or old == "" then return new end
    if not new or new == "" then return old end
    if old:find(new, 1, true) then return old end
    return old .. "_" .. new
end

local function load_pron_map(path)
    if not path or path == "" then return nil end
    if pron_maps[path] ~= nil then return pron_maps[path] or nil end

    local f = io.open(path, "r")
    if not f then
        pron_maps[path] = false
        return nil
    end

    local map = {}
    for line in f:lines() do
        local text, pron = line:match("^([^\t]+)\t%(([^%)]+)%)")
        if text and pron and candidate_util.utf8_len(text) == 1 then
            map[text] = merge_pron(map[text], pron)
        end
    end
    f:close()
    pron_maps[path] = map
    return map
end

local function is_reverse_lookup(env)
    local ctx = env.engine.context
    local seg = ctx and ctx.composition and ctx.composition:back()
    return config_util.segment_has_tag(seg, "reverse_lookup")
end

local function release_pron_cache()
    reverse.clear_pron_cache()
    collectgarbage("step", 48)
end

function M.func(input, env)
    local reverse_mode = is_reverse_lookup(env)
    if not reverse_mode then
        if env._reverse_hint_active then
            env._reverse_hint_active = false
            release_pron_cache()
        end
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    env._reverse_hint_active = true
    local pron_map = nil
    if env._use_pron_map then
        pron_map = load_pron_map(env._pron_map_path)
    end
    for cand in input:iter() do
        if candidate_util.utf8_len(cand.text) == 1 then
            local p = pron_map and pron_map[cand.text] or nil
            if not p then
                p = reverse.lookup_pron(env._cx_dict, cand.text, env._pron_cache_limit)
            end
            if p then
                candidate_util.set_comment(cand, candidate_util.merge_pron_comment(p, cand.comment))
            end
        end
        yield(cand)
    end
end

function M.fini(env)
    release_pron_cache()
    pron_maps = {}
    if env._reverse_shared_acquired then
        reverse.release()
        env._reverse_shared_acquired = nil
    end
    env._reverse_hint_active = nil
    env._cx_dict = nil
    env._pron_cache_limit = nil
    env._use_pron_map = nil
    env._pron_map_path = nil
end

function M.init(env)
    if not env._reverse_shared_acquired then
        reverse.acquire()
        env._reverse_shared_acquired = true
    end
    reverse.reset_failed()
    env._reverse_hint_active = false

    local config = env.engine.schema.config
    env._cx_dict = config_util.resolve_pron_dict(config, env.engine.schema.schema_id or "")
    env._pron_cache_limit = reverse.cache_limit(config, "pron_cache_limit")
    env._use_pron_map = config:get_bool("reverse_hint/use_pron_map") ~= false
    local dict_file = config:get_string("reverse_hint/pron_map_file")
    if not dict_file or dict_file == "" then
        dict_file = (env._cx_dict or "xmjd6.cx") .. ".dict.yaml"
    end
    env._pron_map_path = find_existing_path(dict_file)
end

return M
