-- 内嵌候选显示优化版 (内存池复用版)
-- 文件名：lua/txjx_embeded_cands.lua
-- 优化：2026-02-16 (消除 Table 内存分配，适配 iOS)

local embeded_cands_filter = {}

-- 局部化
local string_len = string.len
local string_sub = string.sub
local string_gsub = string.gsub
local string_format = string.format
local table_insert = table.insert
local table_concat = table.concat
local math_min = math.min
local table_unpack = table.unpack or unpack

-- 弱引用
local ctx_handlers = setmetatable({}, { __mode = "k" })
-- 配置缓存
local config_cache = setmetatable({}, { __mode = "v" })

local DEFAULT_INDEX_INDICATORS = {"¹","²","³","⁴","⁵","⁶","⁷","⁸","⁹","⁰"}
local DEFAULT_FIRST_FORMAT = "${Stash}[${候選}${Seq}]${Code}${Comment}"
local DEFAULT_NEXT_FORMAT = "${Stash}${候選}${Seq}${Comment}"
local DEFAULT_SEPARATOR = " "
local DEFAULT_STASH_PLACEHOLDER = "~"

local safe = {
    truncate = function(text, max_len)
        if not text then return "" end
        return #text <= max_len and text or text:sub(1, max_len).."…"
    end
}

local function compile_formatter(format_str)
    if not format_str then format_str = DEFAULT_FIRST_FORMAT end
    if string_len(format_str) > 60 then format_str = "${候選}${Comment}" end
    local pattern = "%${[^{}]+%}"
    local verbs = {}
    for s in string.gmatch(format_str, pattern) do table_insert(verbs, s) end
    local compiled = {
        format_pattern = string_gsub(format_str, pattern, "%%s"),
        verbs_order = verbs,
    }
    -- 预分配 args 表复用，避免每次 build 创建新表
    local args = {}
    for i = 1, #verbs do args[i] = "" end
    function compiled:build(dict)
        for i = 1, #self.verbs_order do
            args[i] = dict[self.verbs_order[i]] or ""
        end
        return string_format(self.format_pattern, table_unpack(args, 1, #self.verbs_order))
    end
    return compiled
end

-- 辅助逻辑
local function render_comment_text_inline_logic(comment)
    if comment and #comment > 0 and string.byte(comment, 1) == 126 then return "" end -- 126 is '~'
    return comment or ""
end

local function render_stashcand_inline_logic(cfg, seq, stash, text, digested)
    local s, t = stash, text
    local sl, tl = #stash, #text
    if sl > 0 and tl >= sl and string_sub(text, 1, sl) == stash then
        if seq == 1 then
            digested = true
            t = string_sub(text, sl + 1)
        elseif not digested then
            digested = true
            s = "["..stash.."]"
            t = string_sub(text, sl + 1)
        else
            -- 优化：减少 gsub 调用
            local placeholder = cfg.stash_placeholder_str
            s = ""
            t = string_gsub(placeholder, "%${Stash}", stash)..string_sub(text, sl + 1)
        end
    else
        s = ""
    end
    return s, t, digested
end

local function parse_conf_str(env, key, default_val)
    local val = env.engine.schema.config:get_string((env.name_space or "") .. "/" .. key)
    return (val and val ~= "") and val or default_val
end

local function parse_conf_str_list(env, key, default_list)
    local list = nil
    local l = env.engine.schema.config:get_list((env.name_space or "") .. "/" .. key)
    if l then
        list = {}
        for i = 0, l:size() - 1 do
            local v = l:get_value_at(i)
            table_insert(list, v.value or v:get_string())
        end
    end
    return (list and #list > 0) and list or default_list
end

local function get_config(env)
    local ns = env.name_space or "default"
    if not config_cache[ns] then
        local cfg = {}
        -- 使用 pcall 保护 config 读取
        pcall(function()
            cfg.index_indicators = parse_conf_str_list(env, "index_indicators", DEFAULT_INDEX_INDICATORS)
            cfg.first_format_str = parse_conf_str(env, "first_format", DEFAULT_FIRST_FORMAT)
            cfg.next_format_str = parse_conf_str(env, "next_format", DEFAULT_NEXT_FORMAT)
            cfg.separator_str = parse_conf_str(env, "separator", DEFAULT_SEPARATOR)
            cfg.stash_placeholder_str = parse_conf_str(env, "stash_placeholder", DEFAULT_STASH_PLACEHOLDER)
        end)
        cfg.formatter = {
            first = compile_formatter(cfg.first_format_str),
            next = compile_formatter(cfg.next_format_str),
        }
        config_cache[ns] = cfg
    end
    return config_cache[ns]
end

function embeded_cands_filter.init(env)
    env.option = nil
    local ctx = env.engine.context

    if env._embeded_handler and ctx.option_update_notifier then
        pcall(function() ctx.option_update_notifier:disconnect(env._embeded_handler) end)
    end
    ctx_handlers[ctx] = nil

    get_config(env)

    local option_name = "embeded_cands"
    env.option = {}
    local function handler(context, name)
        if name == option_name then
            env.option[name] = context:get_option(name)
        end
    end
    handler(ctx, option_name)
    env._embeded_handler = handler
    ctx_handlers[ctx] = handler
    ctx.option_update_notifier:connect(handler)
    
    -- 核心优化：预分配内存池
    env.page_cands_pool = {} 
    env.page_rendered_pool = {}
    -- 预定义 dict 表，避免 render_candidate 中重复创建
    env.render_dict = {}
end

local function render_candidate(cfg, seq, input_code, stashed_text, text, comment, digested, dict_buffer)
    if #text > 60 then text = safe.truncate(text, 60) end
    if #comment > 60 then comment = safe.truncate(comment, 60) end
    
    local formatter = (seq == 1) and cfg.formatter.first or cfg.formatter.next
    local s, t, d = render_stashcand_inline_logic(cfg, seq, stashed_text, text, digested)
    
    if seq ~= 1 and #t == 0 then return "", d end
    
    local cmt = render_comment_text_inline_logic(comment)
    
    -- 复用传入的 dict_buffer
    dict_buffer["${Seq}"] = cfg.index_indicators[math_min(seq, #cfg.index_indicators)] or ""
    dict_buffer["${Code}"] = input_code or ""
    dict_buffer["${Stash}"] = s
    dict_buffer["${候選}"] = t
    dict_buffer["${Comment}"] = cmt
    
    return formatter:build(dict_buffer), d
end

local function get_page_size(env)
    -- 简化 page_size 获取，假设大部分情况为 5，避免频繁调用 C++ 接口
    return env.engine.schema.page_size or 5
end

function embeded_cands_filter.func(input, env)
    -- 快速路径：如果不开启，直接透传
    if not (env.option and env.option["embeded_cands"]) then
        for cand in input:iter() do yield(cand) end
        return
    end

    local cfg = get_config(env)
    local page_size = get_page_size(env)
    
    -- 使用内存池
    local page_cands = env.page_cands_pool
    local page_rendered = env.page_rendered_pool
    local dict_buffer = env.render_dict
    
    local idx = 0
    local first_cand = nil
    local digested = false
    local active_input_code = env.input_code or ""
    local active_stash = env.stashed_text or ""
    local sep = cfg.separator_str
    
    local preedit = ""
    local cands_count = 0
    local rendered_count = 0

    for cand in input:iter() do
        idx = idx + 1
        if idx == 1 then first_cand = cand end
        
        local code = (#active_input_code == 0) and (cand.preedit or "") or active_input_code
        local cand_text = cand.text or ""
        
        preedit, digested = render_candidate(cfg, idx, code, active_stash, cand_text, cand.comment, digested, dict_buffer)
        
        cands_count = cands_count + 1
        page_cands[cands_count] = cand
        
        if #preedit > 0 then 
            rendered_count = rendered_count + 1
            page_rendered[rendered_count] = preedit 
        end
        
        if idx == page_size then
            if first_cand and rendered_count > 0 then
                -- 使用 table.concat 高效拼接
                first_cand.preedit = table_concat(page_rendered, sep, 1, rendered_count)
            end
            
            for i = 1, cands_count do
                yield(page_cands[i])
                page_cands[i] = nil -- 释放引用
            end
            
            -- 重置状态
            idx = 0
            first_cand = nil
            digested = false
            cands_count = 0
            rendered_count = 0
            -- page_rendered 不需要逐个 nil，下次直接覆盖即可，
            -- 但为了保险防止长串残留，可以清理
            for i=1, page_size do page_rendered[i] = nil end
        end
    end
    
    -- 处理剩余不足一页的候选
    if cands_count > 0 then
        if first_cand and rendered_count > 0 then
            first_cand.preedit = table_concat(page_rendered, sep, 1, rendered_count)
        end
        for i = 1, cands_count do
            yield(page_cands[i])
            page_cands[i] = nil
        end
        for i=1, page_size do page_rendered[i] = nil end
    end
end

function embeded_cands_filter.fini(env)
    local ctx = env.engine and env.engine.context
    if ctx and env._embeded_handler then
        pcall(function() ctx.option_update_notifier:disconnect(env._embeded_handler) end)
    end
    env._embeded_handler = nil
    env.option = nil
    -- 释放内存池
    env.page_cands_pool = nil
    env.page_rendered_pool = nil
    env.render_dict = nil
end

return embeded_cands_filter