-- txjx 内嵌候选模块，此版本经过二次优化 来源：@浮生 https://github.com/wzxmer/rime-txjx
local embeded_cands_filter = {}

-- 本地化常用函数（仅保留实际使用的）
local string_format = string.format
local string_gmatch, string_gsub = string.gmatch, string.gsub
local string_len = string.len
local string_match = string.match
local string_sub = string.sub
local table_concat, table_insert = table.concat, table.insert
local table_unpack = table.unpack or unpack  -- Lua 5.1 兼容性
local math_min = math.min
local ipairs = ipairs
local pcall, type, tostring = pcall, type, tostring
local setmetatable = setmetatable
local coroutine_yield = coroutine.yield
local Candidate = Candidate

-- 默认配置
local DEFAULT_INDEX_INDICATORS = {"¹","²","³","⁴","⁵","⁶","⁷","⁸","⁹","⁰"}
local DEFAULT_FIRST_FORMAT = "${Stash}[${候選}${Seq}]${Code}${Comment}"
local DEFAULT_NEXT_FORMAT = "${Stash}${候選}${Seq}${Comment}"
local DEFAULT_SEPARATOR = " "
local DEFAULT_STASH_PLACEHOLDER = "~"

-- 安全处理模块
local safe = {
    max_text_length = 100,    -- 单个候选最大长度
    max_total_length = 500,   -- 整页候选最大长度
    gc_interval = 200,        -- 每处理 200 个候选词触发一次 GC
    truncate = function(text, max_len)
        if not text then return "" end
        text = tostring(text)
        return #text <= max_len and text or text:sub(1, max_len).."…"
    end
}

-- 格式化模板编译
local function compile_formatter(format_str)
    if not format_str or string_len(format_str) > safe.max_text_length then 
        return compile_formatter(DEFAULT_FIRST_FORMAT)
    end
    local pattern = "%${[^{}]+%}"
    local verbs = {}
    for s in string_gmatch(format_str, pattern) do table_insert(verbs, s) end
    local compiled = {
        format_pattern = string_gsub(format_str, pattern, "%%s"),
        verbs_order = verbs,
    }
    local meta = { __index = function() return "" end }
    function compiled:build(dict)
        setmetatable(dict, meta)
        local args = {}
        for i = 1, #self.verbs_order do
            table_insert(args, dict[self.verbs_order[i]])
        end
        return string_format(self.format_pattern, table_unpack(args))
    end
    return compiled
end

-- comment渲染逻辑，~开头隐藏
local function render_comment_text_inline_logic(comment)
    if comment and string_len(comment) > 0 and string_sub(comment, 1, 1) == "~" then
        return ""
    end
    return comment or ""
end

-- stash渲染逻辑
local function render_stashcand_inline_logic(cfg, seq, stash, text, digested)
    local s, t = stash, text
    local sl, tl = string_len(stash), string_len(text)
    if sl > 0 and tl >= sl and string_sub(text, 1, sl) == stash then
        if seq == 1 then
            digested = true
            t = string_sub(text, sl + 1)
        elseif not digested then
            digested = true
            s = "["..stash.."]"
            t = string_sub(text, sl + 1)
        else
            local placeholder = cfg.stash_placeholder_str
            s = ""
            t = string_gsub(placeholder, "%${Stash}", stash)..string_sub(text, sl + 1)
        end
    else
        s = ""
    end
    return s, t, digested
end

-- 健壮的配置读取，支持schema缺省，自动fallback
local function parse_conf_str(env, key, default_val)
    local val = nil
    pcall(function()
        val = env.engine.schema.config:get_string((env.name_space or "") .. "/" .. key)
    end)
    if not val or val == "" then return default_val end
    return val
end

local function parse_conf_str_list(env, key, default_list)
    local list = nil
    pcall(function()
        local l = env.engine.schema.config:get_list((env.name_space or "") .. "/" .. key)
        if l then
            list = {}
            for i = 0, l:size() - 1 do
                local v = l:get_value_at(i)
                table_insert(list, v.value or v:get_string())
            end
        end
    end)
    if not list or #list == 0 then return default_list end
    return list
end

-- 配置缓存，支持多namespace，使用弱引用防止内存泄漏
local config_cache = {}
setmetatable(config_cache, {__mode = "v"})
local function get_config(env)
    local ns = env.name_space or "default"
    if not config_cache[ns] then
        local cfg = {}
        cfg.index_indicators = parse_conf_str_list(env, "index_indicators", DEFAULT_INDEX_INDICATORS)
        cfg.first_format_str = parse_conf_str(env, "first_format", DEFAULT_FIRST_FORMAT)
        cfg.next_format_str = parse_conf_str(env, "next_format", DEFAULT_NEXT_FORMAT)
        cfg.separator_str = parse_conf_str(env, "separator", DEFAULT_SEPARATOR)
        cfg.stash_placeholder_str = parse_conf_str(env, "stash_placeholder", DEFAULT_STASH_PLACEHOLDER)
        cfg.formatter = {
            first = compile_formatter(cfg.first_format_str),
            next = compile_formatter(cfg.next_format_str),
        }
        config_cache[ns] = cfg
    end
    return config_cache[ns]
end

function embeded_cands_filter.init(env)
    get_config(env)
    local option_name = "embeded_cands"
    env.option = env.option or {}
    local function handler(ctx, name)
        if name == option_name then
            env.option[name] = ctx:get_option(name)
            ctx:refresh_non_confirmed_composition() -- 关键：强制刷新，立即生效
        end
    end
    -- 初始化时同步一次
    handler(env.engine.context, option_name)
    env.engine.context.option_update_notifier:connect(handler)
end

local function render_candidate(cfg, seq, input_code, stashed_text, text, comment, digested)
    -- 安全检查
    if string_len(text) > safe.max_text_length then
        text = safe.truncate(text, safe.max_text_length)
    end
    if string_len(comment) > safe.max_text_length then
        comment = safe.truncate(comment, safe.max_text_length)
    end
    local formatter = (seq == 1) and cfg.formatter.first or cfg.formatter.next
    local s, t, d = render_stashcand_inline_logic(cfg, seq, stashed_text, text, digested)
    if seq ~= 1 and string_len(t) == 0 then return "", d end
    local cmt = render_comment_text_inline_logic(comment)
    local dict = {
        ["${Seq}"] = cfg.index_indicators[math_min(seq, #cfg.index_indicators)] or "",
        ["${Code}"] = input_code or "",
        ["${Stash}"] = s,
        ["${候選}"] = t,
        ["${Comment}"] = cmt,
    }
    return formatter:build(dict), d
end

-- 获取 page_size，优先用 env.page_size，其次 schema 配置，最后默认 5
local function get_page_size(env)
    if env.page_size and type(env.page_size)=="number" then return env.page_size end
    local ok, val = pcall(function()
        return env.engine.schema.page_size
    end)
    if ok and type(val)=="number" then return val end
    return 5
end

function embeded_cands_filter.func(input, env)
    local ok, err = pcall(function()
        local cfg = get_config(env)
        if not cfg or not (env.option and env.option["embeded_cands"]) then
            -- 功能未启用时直接透传
            for cand in input:iter() do
                coroutine_yield(cand)
            end
            return
        end
        local page_size = get_page_size(env)
        local page_cands, page_rendered = {}, {}
        local idx, first_cand, preedit = 0, nil, ""
        local digested = false
        local active_input_code = env.input_code or ""
        local active_stash = env.stashed_text or ""
        local sep = cfg.separator_str
        -- 优化：直接设置为 nil 而不是使用 table.remove
        local function clear(tbl) 
            for i = 1, #tbl do 
                tbl[i] = nil 
            end 
        end
        local iter, obj = input:iter()
        local next_cand = iter(obj)
        while next_cand do
            idx = idx + 1
            local genuine = next_cand:get_genuine()
            if idx == 1 then first_cand = genuine end
            local code = (string_len(active_input_code) == 0) and (next_cand.preedit or "") or active_input_code
            local cand_text = next_cand.text or ""
            preedit, digested = render_candidate(cfg, idx, code, active_stash, cand_text, next_cand.comment, digested)
            table_insert(page_cands, genuine)
            if string_len(preedit) > 0 then table_insert(page_rendered, preedit) end
            if idx == page_size then
                if first_cand and #page_rendered > 0 then
                    first_cand.preedit = table_concat(page_rendered, sep)
                end
                for _, c in ipairs(page_cands) do coroutine_yield(c) end
                idx, first_cand, preedit = 0, nil, ""
                digested = false
                clear(page_cands); clear(page_rendered)
            end
            
            next_cand = iter(obj)
        end
        if idx > 0 and #page_cands > 0 then
            if first_cand and #page_rendered > 0 then
                first_cand.preedit = table_concat(page_rendered, sep)
            end
            for _, c in ipairs(page_cands) do coroutine_yield(c) end
        end
    end)
    if not ok then
        -- 错误时直接透传
        for cand in input:iter() do
            coroutine_yield(cand)
        end
    end
end

function embeded_cands_filter.fini(env)
    config_cache[env.name_space] = nil
    env.option = nil
    collectgarbage("step", 1)
end

-- 保证 return 的 table 直接有 func 方法，兼容简洁 filter 引用
return embeded_cands_filter
