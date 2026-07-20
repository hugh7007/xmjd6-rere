-- cx_pinyin_hint.lua
-- Display pinyin hints from source-only comments in xmjd6.cx.dict.yaml.
--
-- Dictionary rows are kept compiler-friendly:
--   不<TAB>b<TAB>0 # 〔bú_bù〕
-- The Rime compiler only uses text/code/weight, while this filter reads the
-- source comment and appends it to candidate comments at runtime.

local M = {}

local DEFAULT_DICT_FILE = "xmjd6.cx.dict.yaml"
M.DEFAULT_REVERSE_TAGS = { "pinyin_simp", "quanpinerfen", "xmjd6gbk", "reverse_lookup" }

local cache = {
    path = nil,
    mtime = nil,
    map = nil,
}

local function clear_cache()
    cache.path = nil
    cache.mtime = nil
    cache.map = nil
end

do
    local ok, mem_cleaner = pcall(require, "xmjd6.mem_cleaner")
    if ok and mem_cleaner and mem_cleaner.register then
        mem_cleaner.register(clear_cache)
    end
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function text_len(s)
    if type(s) ~= "string" then return 0 end
    if utf8 and utf8.len then
        local n = utf8.len(s)
        if n then return n end
    end
    local n = 0
    for _ in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        n = n + 1
    end
    return n
end

local function path_separator()
    local cfg = package.config or "/"
    return cfg:sub(1, 1) == "\\" and "\\" or "/"
end

local function join_path(dir, name)
    if not dir or dir == "" then return name end
    if not name or name == "" then return dir end
    if name:sub(1, 1) == "/" or name:match("^%a:[/\\]") then return name end
    local sep = path_separator()
    if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
        return dir .. name
    end
    return dir .. sep .. name
end

local function user_data_dir()
    if rime_api and rime_api.get_user_data_dir then
        local ok, dir = pcall(rime_api.get_user_data_dir)
        if ok and dir and dir ~= "" then return dir end
    end
    return "."
end

local function file_mtime(path)
    local lfs_ok, lfs = pcall(require, "lfs")
    if lfs_ok and lfs.attributes then
        local ok, attr = pcall(lfs.attributes, path, "modification")
        if ok and attr then return attr end
    end
    local f = io.open(path, "r")
    if not f then return 0 end
    local size = f:seek("end") or 0
    f:close()
    return size
end

local function strip_brackets(pinyin)
    if type(pinyin) ~= "string" then return "" end
    local inner = pinyin:match("^〔(.*)〕$")
    return inner or pinyin
end

local function split_pinyin_parts(pinyin)
    local parts = {}
    local inner = strip_brackets(pinyin)
    for part in inner:gmatch("[^_/%s]+") do
        parts[#parts + 1] = part
    end
    return parts
end

local function merge_pinyin(old, new)
    if not old or old == "" then return new end
    if not new or new == "" then return old end

    local seen = {}
    local merged = {}
    local function add_all(pinyin)
        for _, part in ipairs(split_pinyin_parts(pinyin)) do
            if part ~= "" and not seen[part] then
                seen[part] = true
                merged[#merged + 1] = part
            end
        end
    end
    add_all(old)
    add_all(new)
    return "〔" .. table.concat(merged, "_") .. "〕"
end

function M.parse_line(line)
    if type(line) ~= "string" or line == "" or line:sub(1, 1) == "#" then
        return nil, nil
    end
    local text, rest = line:match("^([^\t]+)\t(.+)$")
    if not text or not rest then return nil, nil end

    local code = rest:match("^([a-z;]+)%s+")
              or rest:match("^([a-z;]+)$")
    if not code then return nil, nil end

    -- Only source-only comments after # are used.  This avoids treating old
    -- polluted code fields as valid display metadata.
    local pinyin = rest:match("#%s*(〔[^〕]+〕)")
    if not pinyin then return nil, nil end
    return trim(text), pinyin
end

function M.load_map(path)
    local map = {}
    local f = io.open(path, "r")
    if not f then return map end
    for line in f:lines() do
        local text, pinyin = M.parse_line(line)
        if text and pinyin and text_len(text) == 1 then
            map[text] = merge_pinyin(map[text], pinyin)
        end
    end
    f:close()
    return map
end

local function get_map(path)
    local mtime = file_mtime(path)
    if cache.map and cache.path == path and cache.mtime == mtime then
        return cache.map
    end
    cache.path = path
    cache.mtime = mtime
    cache.map = M.load_map(path)
    return cache.map
end

function M.append_comment(comment, pinyin)
    if not pinyin or pinyin == "" then return comment or "" end
    comment = comment or ""
    if comment:find(pinyin, 1, true) then
        return comment
    end
    return comment .. pinyin
end

function M.should_hint(text, only_single_char)
    if not text or text == "" then return false end
    if only_single_char == false then return true end
    return text_len(text) == 1
end

function M.is_reverse_lookup_input(input)
    if type(input) ~= "string" or input == "" then return false end
    if input:find("`", 1, true) then return true end
    if input:match("^u[a-z']*'?$") then return true end
    if input:match("^v[a-z']*'?$") then return true end
    if input:match("^o[a-z]*$") then return true end
    return false
end

local function get_composition_segment(context)
    if not context then return nil end
    local comp = context.composition
    if type(comp) == "function" then
        local ok, value = pcall(function() return context:composition() end)
        if ok then comp = value end
    end
    if not comp then return nil end

    local ok, seg = pcall(function() return comp:back() end)
    if ok and seg then return seg end

    ok, seg = pcall(function()
        local size = comp:size()
        if size and size > 0 then
            return comp:at(size - 1)
        end
        return nil
    end)
    if ok then return seg end
    return nil
end

function M.has_reverse_lookup_tag(context, reverse_tags)
    local seg = get_composition_segment(context)
    if not seg then return nil end
    reverse_tags = reverse_tags or M.DEFAULT_REVERSE_TAGS

    local checked = false
    for _, tag in ipairs(reverse_tags) do
        if type(seg.has_tag) == "function" then
            local ok, value = pcall(function() return seg:has_tag(tag) end)
            if ok then
                checked = true
                if value then return true end
            end
        end
    end
    if checked then return false end

    local tags = seg.tags
    if type(tags) == "table" then
        checked = true
        for _, tag in ipairs(reverse_tags) do
            if tags[tag] then return true end
            for _, value in pairs(tags) do
                if value == tag then return true end
            end
        end
    end
    if checked then return false end
    return nil
end

function M.should_apply(context, reverse_only, reverse_tags)
    if reverse_only == false then return true end
    local by_tag = M.has_reverse_lookup_tag(context, reverse_tags)
    if by_tag ~= nil then return by_tag end
    return M.is_reverse_lookup_input(context and context.input)
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

function M.init(env)
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    env.cx_pinyin_hint_enabled = get_bool(config, "cx_pinyin_hint/enabled", true)
    env.cx_pinyin_hint_reverse_only = get_bool(config, "cx_pinyin_hint/reverse_only", true)
    env.cx_pinyin_hint_only_single_char = get_bool(config, "cx_pinyin_hint/only_single_char", true)
    local dict_file = get_string(config, "cx_pinyin_hint/dict_file", DEFAULT_DICT_FILE)
    env.cx_pinyin_hint_path = join_path(user_data_dir(), dict_file)
end

function M.fini(env)
    if env then
        env.cx_pinyin_hint_path = nil
    end
end

function M.func(input, env)
    if not env or env.cx_pinyin_hint_enabled == false then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local context = env.engine and env.engine.context
    if not M.should_apply(context, env.cx_pinyin_hint_reverse_only, M.DEFAULT_REVERSE_TAGS) then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local map = get_map(env.cx_pinyin_hint_path or DEFAULT_DICT_FILE)
    for cand in input:iter() do
        local text = cand.text
        if M.should_hint(text, env.cx_pinyin_hint_only_single_char) then
            local pinyin = map[text]
            if pinyin then
                local ok, genuine = pcall(function() return cand:get_genuine() end)
                if ok and genuine then
                    genuine.comment = M.append_comment(genuine.comment or cand.comment or "", pinyin)
                else
                    cand.comment = M.append_comment(cand.comment or "", pinyin)
                end
            end
        end
        yield(cand)
    end
end

return M
