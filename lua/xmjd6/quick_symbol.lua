-- quick_symbol.lua
-- Auto-commit semicolon symbol codes only when the completed code has exactly
-- one candidate and no longer completion candidates.  Example: ;q -> ~.

local M = {}

local kAccepted = 1
local kNoop = 2

local DEFAULT_DICT_FILE = "xmjd6.fuhao.dict.yaml"
local DEFAULT_OPTION_NAME = "quick_symbol_enabled"

local FALLBACK_ENTRIES = {
    { text = "~", code = ";q" },
    { text = "!", code = ";a" },
    { text = "?", code = ";w" },
}

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function path_separator()
    local cfg = package.config or "/"
    return cfg:sub(1, 1) == "\\" and "\\" or "/"
end

local function join_path(dir, name)
    if not dir or dir == "" then return name end
    local sep = path_separator()
    if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
        return dir .. name
    end
    return dir .. sep .. name
end

local function try_call(fn)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function is_absolute_path(path)
    if type(path) ~= "string" or path == "" then return false end
    if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then return true end
    return path:match("^%a:[/\\]") ~= nil
end

local function file_exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

local function find_data_file(name)
    if not name or name == "" then return nil end
    if is_absolute_path(name) and file_exists(name) then
        return name
    end

    local candidates = {}
    if rime_api then
        local user_dir = try_call(rime_api.get_user_data_dir)
        local shared_dir = try_call(rime_api.get_shared_data_dir)
        if user_dir and user_dir ~= "" then candidates[#candidates + 1] = join_path(user_dir, name) end
        if shared_dir and shared_dir ~= "" then candidates[#candidates + 1] = join_path(shared_dir, name) end
    end
    candidates[#candidates + 1] = name
    candidates[#candidates + 1] = join_path(".", name)

    for _, path in ipairs(candidates) do
        if file_exists(path) then return path end
    end
    return nil
end

local function new_symbol_data()
    return {
        exact = {},
        prefix_count = {},
        total = 0,
    }
end

local function add_entry(data, text, code)
    text = trim(text)
    code = trim(code)
    if text == "" or code == "" or code:sub(1, 1) ~= ";" then return end
    if #code < 2 then return end

    local list = data.exact[code]
    if not list then
        list = {}
        data.exact[code] = list
    end
    list[#list + 1] = text
    data.total = data.total + 1

    for i = 1, #code do
        local prefix = code:sub(1, i)
        data.prefix_count[prefix] = (data.prefix_count[prefix] or 0) + 1
    end
end

local function parse_dict_line(data, line)
    if type(line) ~= "string" or line == "" then return end
    if line:sub(1, 1) == "#" then return end
    local text, code = line:match("^([^\t]+)\t([^\t]+)")
    if not text or not code then return end
    add_entry(data, text, code)
end

local function load_from_file(path)
    local data = new_symbol_data()
    local f = io.open(path, "r")
    if not f then return data end
    for line in f:lines() do
        parse_dict_line(data, line)
    end
    f:close()
    return data
end

local function load_fallback()
    local data = new_symbol_data()
    for _, entry in ipairs(FALLBACK_ENTRIES) do
        add_entry(data, entry.text, entry.code)
    end
    return data
end

local function get_config(env)
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    return config
end

local function get_bool(config, key, default)
    if not config or not config.get_bool then return default end
    local ok, value = pcall(function() return config:get_bool(key) end)
    if ok and value ~= nil then return value end
    return default
end

local function get_string(config, key, default)
    if not config or not config.get_string then return default end
    local ok, value = pcall(function() return config:get_string(key) end)
    if ok and value and value ~= "" then return value end
    return default
end

local function get_context(env)
    return env and env.engine and env.engine.context or nil
end

local function get_context_option(context, name)
    if not context or not context.get_option or not name or name == "" then return nil end
    local ok, value = pcall(function() return context:get_option(name) end)
    if ok then return value end
    return nil
end

function M.is_enabled(env)
    local config = get_config(env)
    if get_bool(config, "quick_symbol/enabled", true) == false then return false end

    local option_name = get_string(config, "quick_symbol/option_name", DEFAULT_OPTION_NAME)
    local option_value = get_context_option(get_context(env), option_name)
    if option_value == false then return false end

    return true
end

function M.is_ascii_mode(env)
    return get_context_option(get_context(env), "ascii_mode") == true
end

function M.load_symbols(env)
    local config = get_config(env)
    local dict_file = get_string(config, "quick_symbol/dict_file", DEFAULT_DICT_FILE)
    local cache = env and env.__quick_symbol_cache
    if cache and cache.dict_file == dict_file then
        return cache.data
    end

    local path = find_data_file(dict_file)
    local data = path and load_from_file(path) or new_symbol_data()
    if data.total == 0 then
        data = load_fallback()
    end

    if env then
        env.__quick_symbol_cache = {
            dict_file = dict_file,
            data = data,
        }
    end
    return data
end

function M.unique_symbol(input, data)
    if type(input) ~= "string" or input == "" then return nil end
    data = data or load_fallback()
    local list = data.exact[input]
    if not list or #list ~= 1 then return nil end
    if (data.prefix_count[input] or 0) ~= 1 then return nil end
    return list[1]
end

local function key_to_char(key)
    local ch = key and key.keycode
    if ch and ch >= 0x20 and ch < 0x7f then
        return string.char(ch)
    end

    local repr = key and key.repr and key:repr() or ""
    if #repr == 1 then return repr end
    if repr == "semicolon" then return ";" end
    if repr == "apostrophe" then return "'" end
    return nil
end

function M.processor(key, env)
    if not key or key:release() or key:ctrl() or key:alt() or key:super() then
        return kNoop
    end
    if not M.is_enabled(env) or M.is_ascii_mode(env) then
        return kNoop
    end

    local engine = env and env.engine
    local context = engine and engine.context
    if not engine or not engine.commit_text or not context then
        return kNoop
    end

    local current_input = context.input or ""
    if current_input:sub(1, 1) ~= ";" then
        return kNoop
    end

    local ch = key_to_char(key)
    if not ch then return kNoop end

    local next_input = current_input .. ch
    local symbol = M.unique_symbol(next_input, M.load_symbols(env))
    if not symbol then
        return kNoop
    end

    engine:commit_text(symbol)
    if context.clear then context:clear() end
    return kAccepted
end

local function make_candidate(seg, text)
    local cand = Candidate("quick_symbol", seg and seg.start or 0, seg and seg._end or #text, text, "")
    cand.quality = 500000
    return cand
end

function M.translator(input, seg, env)
    if not M.is_enabled(env) or M.is_ascii_mode(env) then
        return
    end

    local symbol = M.unique_symbol(input, M.load_symbols(env))
    if not symbol then
        return
    end

    yield(make_candidate(seg, symbol))
end

function M.func(key, env)
    return M.processor(key, env)
end

return M
