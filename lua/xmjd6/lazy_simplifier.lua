-- 按需加载的轻量 simplifier 替代,降低 OpenCC 字典常驻内存
--
-- 工作模式(由 namespace 配置 mode 字段决定):
--   char  逐 UTF-8 字符替换(适合 mars/tofu 这类全字符变体表)
--   word  整词匹配,命中则在原候选之后追加 emoji/变体候选
--
-- 字典与 OpenCC 文本字典格式兼容:每行 "key<TAB>v1 v2 v3 ..."
-- 加载时机: 仅在对应开关打开 + filter 被调用时才加载
-- 释放时机:
--   1) 开关关闭后,第一次空闲过 idle_timeout 秒,释放字典 + 触发 GC
--   2) Rime 销毁该 filter 实例时(fini)立即释放
--
-- emoji 分片按需加载（参考浮生方案）:
--   chars 表全量加载, phrases 按首字母分片 LRU 缓存
--   不再使用单个大 phrases 文件,降低常驻内存
--
-- 在 schema 里使用:
--   filters:
--     - lua_filter@*xmjd6/lazy_simplifier@emoji_cn
--   emoji_cn:
--     option_name: emoji_cn
--     dict_file: emoji.txt
--     mode: word
--     force_comment: " "    # 可选,所有新增候选用此 comment;不写则继承原候选 comment
--     idle_timeout: 30      # 可选,默认 30 秒

local M = {}

local mem_cleaner = require("xmjd6.mem_cleaner")

local DEFAULT_IDLE_TIMEOUT = 30

local function get_dict_path(filename)
    if not filename or filename == "" then return nil end
    local source = debug.getinfo(1).source or ""
    local script_dir = source:match("@?(.*/)")
    if not script_dir then return nil end
    return script_dir .. "../../opencc/" .. filename
end

-- 预编译 Lua 表文件名映射
-- txt 文件 → 预编译 lua 表文件（位于 opencc/Data/ 下）
-- emoji.txt 的 phrases 走分片按需加载,不在此全量加载
local LUA_TABLE_MAP = {
    ["mars.txt"]  = { mode = "char",  files = { "Data/xmjd6_mars_chars.lua" } },
    ["tofu.txt"]  = { mode = "char",  files = { "Data/xmjd6_tofu_chars.lua" } },
    ["emoji.txt"] = { mode = "word",  files = { "Data/xmjd6_emoji_chars.lua" } },
}

-- emoji 分片按需加载（参考浮生方案）
local PHRASE_SHARD_LIMIT = 8  -- 最多同时驻留 8 个分片
local phrase_shards = {}      -- module_name → table
local phrase_usage = {}       -- LRU 顺序
local phrase_index = nil      -- 首字母→分片号 索引表

local function get_opencc_base()
    local source = debug.getinfo(1).source or ""
    local script_dir = source:match("@?(.*/)")
    if not script_dir then return nil end
    return script_dir .. "../../opencc/"
end

local function load_lua_file(base, rel)
    if not base or not rel then return nil end
    local path = base .. rel
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, tbl = pcall(chunk)
    if ok and type(tbl) == "table" then return tbl end
    return nil
end

local function utf8_first_char(text)
    if not text or text == "" then return nil end
    local b = text:byte(1)
    if not b then return nil end
    local len = 1
    if b >= 0xF0 then len = 4
    elseif b >= 0xE0 then len = 3
    elseif b >= 0xC0 then len = 2
    end
    return text:sub(1, len)
end

local function touch_shard(module_name)
    for i = #phrase_usage, 1, -1 do
        if phrase_usage[i] == module_name then
            table.remove(phrase_usage, i)
            break
        end
    end
    table.insert(phrase_usage, module_name)
    while #phrase_usage > PHRASE_SHARD_LIMIT do
        local expired = table.remove(phrase_usage, 1)
        if expired and expired ~= module_name then
            phrase_shards[expired] = nil
        end
    end
end

local function get_phrase_shard(base, first_char)
    if not base or not first_char then return nil end
    if not phrase_index then
        phrase_index = load_lua_file(base, "Data/xmjd6_emoji_phrases_index.lua") or {}
    end
    local bucket = phrase_index[first_char]
    if not bucket then return nil end
    local module_name = "xmjd6_emoji_phrases_" .. bucket .. ".lua"
    if phrase_shards[module_name] then
        touch_shard(module_name)
        return phrase_shards[module_name]
    end
    local shard = load_lua_file(base, "Data/" .. module_name)
    if not shard then return nil end
    phrase_shards[module_name] = shard
    touch_shard(module_name)
    return shard
end

-- emoji 专用: 分片按需查询
local function emoji_lookup(base, chars, text)
    if not text or text == "" then return nil end
    local first = utf8_first_char(text)
    if not first then return nil end
    if #first == #text then
        return chars and chars[text]
    end
    local shard = get_phrase_shard(base, first)
    if shard then
        local val = shard[text]
        if val then return val end
    end
    return chars and chars[text]
end

local function clear_phrase_cache()
    phrase_shards = {}
    phrase_usage = {}
    phrase_index = nil
end

local function load_dict(filename, mode)
    local lua_map = LUA_TABLE_MAP[filename]
    if lua_map then
        local base = get_opencc_base()
        if base then
            local combined = {}
            for _, rel in ipairs(lua_map.files) do
                local tbl = load_lua_file(base, rel)
                if tbl then
                    for k, v in pairs(tbl) do
                        combined[k] = v
                    end
                end
            end
            if next(combined) then
                return combined
            end
        end
    end

    -- 回退:逐行 parse 文本字典
    local path = get_dict_path(filename)
    if not path then return {} end
    local f = io.open(path, "r")
    if not f then return {} end
    local dict = {}
    for line in f:lines() do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, rest = line:match("^([^\t]+)\t(.+)$")
            if k and rest then
                if mode == "word" then
                    local list = {}
                    for v in rest:gmatch("%S+") do
                        if v ~= k then list[#list + 1] = v end
                    end
                    if #list > 0 then dict[k] = list end
                else
                    local v = rest:match("^(%S+)")
                    if v and v ~= k then dict[k] = v end
                end
            end
        end
    end
    f:close()
    return dict
end

-- 按 UTF-8 边界切分,逐字符在字典里查替换
local function replace_chars(text, dict)
    local out = {}
    local i, n = 1, #text
    local changed = false
    while i <= n do
        local b = text:byte(i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2
        end
        local ch = text:sub(i, i + len - 1)
        local mapped = dict[ch]
        if mapped then
            out[#out + 1] = mapped
            changed = true
        else
            out[#out + 1] = ch
        end
        i = i + len
    end
    return table.concat(out), changed
end

local function release_if_idle(env)
    if env.dict and env.last_use_time then
        if os.difftime(os.time(), env.last_use_time) > env.idle_timeout then
            env.dict = nil
            env.last_use_time = nil
            if env.is_emoji then
                clear_phrase_cache()
            end
            collectgarbage("collect")
        end
    end
end

function M.init(env)
    local ns = env.name_space or ""
    local cfg = env.engine.schema.config
    if ns == "" or not cfg then
        env.disabled = true
        return
    end
    env.option_name   = cfg:get_string(ns .. "/option_name") or ns
    env.dict_file     = cfg:get_string(ns .. "/dict_file") or ""
    env.mode          = cfg:get_string(ns .. "/mode") or "char"
    env.force_comment = cfg:get_string(ns .. "/force_comment")
    env.idle_timeout  = cfg:get_int(ns .. "/idle_timeout") or DEFAULT_IDLE_TIMEOUT
    env.dict = nil
    env.last_use_time = nil
    env.disabled = (env.dict_file == "")
    env.is_emoji = (env.dict_file == "emoji.txt" and env.mode == "word")
    env.mem_release = mem_cleaner.register(function()
        env.dict = nil
        env.last_use_time = nil
        if env.is_emoji then
            clear_phrase_cache()
        end
    end)
end

function M.fini(env)
    mem_cleaner.unregister(env.mem_release)
    env.mem_release = nil
    env.dict = nil
    env.last_use_time = nil
    clear_phrase_cache()
    collectgarbage("collect")
end

function M.func(input, env)
    if env.disabled then
        for cand in input:iter() do yield(cand) end
        return
    end

    local on = env.engine.context:get_option(env.option_name)
    if not on then
        release_if_idle(env)
        for cand in input:iter() do yield(cand) end
        return
    end

    -- 反查模式（` / u / v / o）下全 suppress：emoji / mars / tofu 都不追加
    -- 整句连打（a 前缀）下仅 suppress emoji，mars / tofu 照常生效
    --   （此 M.func 被 @emoji_cn / @mars / @tofu 三实例共用，
    --    反查要原始字符故全跳；整句只去 emoji，手机缺字替换与火星文不应受影响）
    local ctx_input = env.engine.context.input or ""
    local is_reverse = ctx_input:find("`", 1, true)
        or ctx_input:match("^u[a-z']*'?$")
        or ctx_input:match("^v[a-z']*'?$")
        or ctx_input:match("^o[a-z0-9]+$")
    local is_sentence = ctx_input:match("^a[a-z']*$")
    if is_reverse or (is_sentence and env.is_emoji) then
        for cand in input:iter() do yield(cand) end
        return
    end

    if not env.dict then
        env.dict = load_dict(env.dict_file, env.mode)
    end
    env.last_use_time = os.time()

    local force_comment = env.force_comment

    if env.mode == "word" then
        if env.is_emoji then
            -- emoji 分片按需加载模式
            local base = get_opencc_base()
            local chars = env.dict
            for cand in input:iter() do
                yield(cand)
                local val = emoji_lookup(base, chars, cand.text)
                if val then
                    local cmt = force_comment or cand:get_genuine().comment
                    -- val 可能是 string 或 table
                    if type(val) == "string" then
                        -- 浮生格式: 空格分隔的值
                        for v in val:gmatch("%S+") do
                            if v ~= cand.text then
                                yield(Candidate(cand.type, cand.start, cand._end, v, cmt))
                            end
                        end
                    elseif type(val) == "table" then
                        -- 旧格式: table 列表
                        for _, v in ipairs(val) do
                            if v ~= cand.text then
                                yield(Candidate(cand.type, cand.start, cand._end, v, cmt))
                            end
                        end
                    end
                end
            end
        else
            -- 普通 word 模式
            for cand in input:iter() do
                yield(cand)
                local list = env.dict[cand.text]
                if list then
                    local cmt = force_comment or cand:get_genuine().comment
                    for _, v in ipairs(list) do
                        yield(Candidate(cand.type, cand.start, cand._end, v, cmt))
                    end
                end
            end
        end
    else
        for cand in input:iter() do
            local replaced, changed = replace_chars(cand.text, env.dict)
            if changed then
                local cmt = force_comment or cand:get_genuine().comment
                yield(Candidate(cand.type, cand.start, cand._end, replaced, cmt))
            end
            yield(cand)
        end
    end
end

return M
