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
local LUA_TABLE_MAP = {
    ["mars.txt"]  = { mode = "char",  files = { "Data/xmjd6_mars_chars.lua" } },
    ["tofu.txt"]  = { mode = "char",  files = { "Data/xmjd6_tofu_chars.lua" } },
    ["emoji.txt"] = { mode = "word",  files = { "Data/xmjd6_emoji_chars.lua", "Data/xmjd6_emoji_phrases.lua" } },
}

local function load_dict(filename, mode)
    -- 优先尝试加载预编译 Lua 表
    local lua_map = LUA_TABLE_MAP[filename]
    if lua_map then
        local source = debug.getinfo(1).source or ""
        local script_dir = source:match("@?(.*/)")
        if script_dir then
            local base = script_dir .. "../../opencc/"
            local combined = {}
            for _, rel in ipairs(lua_map.files) do
                local path = base .. rel
                local chunk = loadfile(path)
                if chunk then
                    local tbl = chunk()
                    if type(tbl) == "table" then
                        for k, v in pairs(tbl) do
                            combined[k] = v
                        end
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
    env.force_comment = cfg:get_string(ns .. "/force_comment")  -- nil 表示继承原 comment
    env.idle_timeout  = cfg:get_int(ns .. "/idle_timeout") or DEFAULT_IDLE_TIMEOUT
    env.dict = nil
    env.last_use_time = nil
    env.disabled = (env.dict_file == "")
    -- 注册到统一清理：iOS 键盘收起 sentinel 到达时释放字典
    env.mem_release = mem_cleaner.register(function()
        env.dict = nil
        env.last_use_time = nil
    end)
end

function M.fini(env)
    mem_cleaner.unregister(env.mem_release)
    env.mem_release = nil
    env.dict = nil
    env.last_use_time = nil
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

    if not env.dict then
        env.dict = load_dict(env.dict_file, env.mode)
    end
    env.last_use_time = os.time()

    local force_comment = env.force_comment

    if env.mode == "word" then
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
