-- 内嵌候选模块（Embedded Candidates Filter）
-- 功能：在编码区内嵌显示候选词，节省屏幕空间
-- 特点：
--   1. 支持动态开关（embeded_cands）监听，立即生效
--   2. 配置缓存，支持多 namespace，使用弱引用防止内存泄漏
--   3. 安全处理，限制文本长度，错误时自动透传
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-01-25

local embeded_cands_filter = {}

-- 本地化常用函数，提升性能
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

-- UTF-8 安全的字符串处理
local utf8 = utf8 or require("utf8")
local function utf8_sub(s, i, j)
    i = utf8.offset(s, i) or (#s + 1)
    j = (j and utf8.offset(s, j + 1) or (#s + 1)) - 1
    return string.sub(s, i, j)
end

-- 安全处理模块
local safe = {
    max_text_length = 100,    -- 单个候选最大字符长度（UTF-8字符数）
    truncate = function(text, max_len)
        if not text then return "" end
        text = tostring(text)
        local char_count = utf8.len(text) or #text
        if char_count <= max_len then return text end
        return utf8_sub(text, 1, max_len).."…"
    end
}

-- 编译格式化模板，将 ${变量} 转换为 %s
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

-- 渲染 comment，~ 开头的 comment 隐藏（UTF-8 安全）
local function render_comment_text_inline_logic(comment)
    if not comment then return "" end
    local len = utf8.len(comment)
    if len and len > 0 then
        local first_char = utf8_sub(comment, 1, 1)
        if first_char == "~" then
            return ""
        end
    end
    return comment
end

-- 渲染 stash 候选，处理重复前缀的显示逻辑（UTF-8 安全）
local function render_stashcand_inline_logic(cfg, seq, stash, text, digested)
    local s, t = stash, text
    if not stash or not text then
        return "", text or "", digested
    end

    local sl = utf8.len(stash) or 0
    local tl = utf8.len(text) or 0

    if sl > 0 and tl >= sl then
        local text_prefix = utf8_sub(text, 1, sl)
        if text_prefix == stash then
            if seq == 1 then
                digested = true
                t = utf8_sub(text, sl + 1, tl)
            elseif not digested then
                digested = true
                s = "["..stash.."]"
                t = utf8_sub(text, sl + 1, tl)
            else
                local placeholder = cfg.stash_placeholder_str
                s = ""
                t = string_gsub(placeholder, "%${Stash}", stash)..utf8_sub(text, sl + 1, tl)
            end
        else
            s = ""
        end
    else
        s = ""
    end
    return s, t, digested
end

-- 读取字符串配置，支持 schema 缺省，自动 fallback
local function parse_conf_str(env, key, default_val)
    local val = nil
    pcall(function()
        val = env.engine.schema.config:get_string((env.name_space or "") .. "/" .. key)
    end)
    if not val or val == "" then return default_val end
    return val
end

-- 读取列表配置
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

-- 配置缓存，使用弱引用防止内存泄漏
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

-- 初始化函数
function embeded_cands_filter.init(env)
    get_config(env)
    local option_name = "embeded_cands"
    env.option = env.option or {}

    local ctx = env.engine.context

    -- 定义选项更新回调函数
    -- 注意：不要在闭包中捕获 ctx，避免循环引用
    local function handler(context, name)
        if name == option_name then
            env.option[name] = context:get_option(name)
            context:refresh_non_confirmed_composition()  -- 强制刷新，立即生效
        end
    end

    -- 保存 handler 引用供 fini 断开，防止内存泄漏
    env._embeded_handler = handler

    -- 初始化时同步一次开关状态
    handler(ctx, option_name)
    ctx.option_update_notifier:connect(handler)
end

-- 渲染单个候选词
local function render_candidate(cfg, seq, input_code, stashed_text, text, comment, digested)
    -- 安全检查，使用 UTF-8 字符数判断
    local text_len = utf8.len(text) or string_len(text)
    if text_len > safe.max_text_length then
        text = safe.truncate(text, safe.max_text_length)
    end
    local comment_len = utf8.len(comment) or string_len(comment)
    if comment_len > safe.max_text_length then
        comment = safe.truncate(comment, safe.max_text_length)
    end
    local formatter = (seq == 1) and cfg.formatter.first or cfg.formatter.next
    local s, t, d = render_stashcand_inline_logic(cfg, seq, stashed_text, text, digested)
    -- 使用 UTF-8 长度判断是否为空
    local t_len = utf8.len(t) or string_len(t)
    if seq ~= 1 and t_len == 0 then return "", d end
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

-- 获取页面大小
local function get_page_size(env)
    if env.page_size and type(env.page_size)=="number" then return env.page_size end
    local ok, val = pcall(function()
        return env.engine.schema.page_size
    end)
    if ok and type(val)=="number" then return val end
    return 5
end

-- 候选词过滤函数
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

        -- 获取当前输入码和已上屏文本，优先从 context 获取
        local ctx = env.engine.context
        local active_input_code = env.input_code or (ctx and ctx.input or "") or ""
        local active_stash = env.stashed_text or (ctx and ctx.commit_history:latest_text() or "") or ""
        local sep = cfg.separator_str

        -- 高效清空表，避免 table.remove
        local function clear(tbl)
            for i = 1, #tbl do
                tbl[i] = nil
            end
        end

        local iter, obj = input:iter()
        local next_cand = iter(obj)
        while next_cand do
            idx = idx + 1
            -- 获取原始候选（genuine）用于读写 comment 和 preedit
            local genuine = next_cand:get_genuine()
            if idx == 1 then first_cand = genuine end  -- 保存 genuine，确保 preedit 设置生效
            -- 使用 UTF-8 长度判断
            local code_len = utf8.len(active_input_code) or string_len(active_input_code)
            local code = (code_len == 0) and (next_cand.preedit or "") or active_input_code
            -- 从原始候选获取 text 和 comment（确保拿到 txjx_filter 设置的630提示）
            -- 从 next_cand 获取 text 以显示 OpenCC 转换后的内容（表情/繁体）
            local cand_text = next_cand.text or ""
            local cand_comment = genuine.comment or next_cand.comment or ""
            preedit, digested = render_candidate(cfg, idx, code, active_stash, cand_text, cand_comment, digested)
            table_insert(page_cands, next_cand)
            local preedit_len = utf8.len(preedit) or string_len(preedit)
            if preedit_len > 0 then table_insert(page_rendered, preedit) end
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
        -- 错误时直接透传，保证输入法正常运行
        for cand in input:iter() do
            coroutine_yield(cand)
        end
    end
end

-- 清理函数
function embeded_cands_filter.fini(env)
    -- 断开监听器，防止内存泄漏
    if env._embeded_handler then
        pcall(function()
            env.engine.context.option_update_notifier:disconnect(env._embeded_handler)
        end)
        env._embeded_handler = nil
    end
    config_cache[env.name_space] = nil
    env.option = nil
    collectgarbage("step", 1)
end

return embeded_cands_filter
