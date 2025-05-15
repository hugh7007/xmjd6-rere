-- 优化版filter  来源：@浮生 https://github.com/wzxmer/rime-txjx
-- 常量定义（维护性提升）
local DEFAULT_HINT_TEXT = "🚫"
local CONFIG_KEYS = {
    TOPUP_THIS = "topup/topup_this",
    TOPUP_WITH = "topup/topup_with",
    DICT = "translator/dictionary",
    HINT_TEXT = "hint_text"
}

-- 局部化标准库函数（性能优化）
local string_gsub = string.gsub
local string_sub = string.sub
local string_match = string.match
local utf8_len = utf8.len

-- 模块容器
local M = {}

--- 安全转义正则特殊字符（保持原始转义逻辑）
local function escape_pattern(s)
    return s and string_gsub(s, "([%-%]%^])", "%%%1") or ""
end

--- 字符串前缀匹配（保持原始逻辑）
local function startswith(str, start)
    if type(str) ~= "string" or type(start) ~= "string" then return false end
    if #start == 0 then return true end
    if #str < #start then return false end
    return string_sub(str, 1, #start) == start
end

--- 带缓存的提示匹配（保持原始匹配顺序）
local function hint_optimized(cand, env)
    local cand_text = cand.text
    if utf8_len(cand_text) < 2 then return false end
    
    local context = env.engine.context
    local reverse = env.cached_reverse_lookup
    local s = env.cached_s_escaped or ''
    local b = env.cached_b_escaped or ''
    if s == '' and b == '' then return false end
    
    local lookup = " " .. reverse:lookup(cand_text) .. " "
    local short
    
    -- 严格保持原始匹配顺序
    if #s > 0 and #b > 0 then
        short = string_match(lookup, " (["..s.."]["..s.."]["..b.."]) ") or
                string_match(lookup, " (["..b.."]["..b.."]["..b.."]) ") or
                string_match(lookup, " (["..s.."]["..b.."]+) ") or
                string_match(lookup, " (["..s.."]["..s.."]) ")
    elseif #s > 0 then
        short = string_match(lookup, " (["..s.."]["..s.."]) ")
    elseif #b > 0 then
        short = string_match(lookup, " (["..b.."]["..b.."]) ")
    end
    
    local input = context.input 
    if short and utf8_len(input) > utf8_len(short) and not startswith(short, input) then
        local genuine = cand:get_genuine()
        genuine.comment = (genuine.comment or "") .. " = " .. short
        return true
    end
    return false
end

--- 单字模式判断（保持原始逻辑）
local function is_danzi_candidate(cand)
    return utf8_len(cand.text) < 2
end

--- 提交提示处理（保持原始逻辑）
local function apply_commit_hint(cand, hint_text)
    cand:get_genuine().comment = hint_text .. (cand.comment or "")
end

function M.filter(input, env)
    -- 环境变量一次性读取（性能优化）
    local context = env.engine.context
    local is_danzi_mode = context:get_option('danzi_mode')
    local show_hint = context:get_option('sbb_hint')
    local input_text = context.input
    local input_len = #input_text

    -- 使用预缓存值
    local cached = {
        hint_text = env.cached_hint_text,
        s_escaped = env.cached_s_escaped,
        b_escaped = env.cached_b_escaped,
        reverse_lookup = env.cached_reverse_lookup
    }

    -- 提前计算提交提示状态（保持原始逻辑）
    local no_commit = (input_len < 4 and cached.s_escaped ~= '' and string_match(input_text, "^["..cached.s_escaped.."]+$")) or 
                     (cached.b_escaped ~= '' and string_match(input_text, "^["..cached.b_escaped.."]+$"))

    -- 候选词处理（保持原始流程）
    local is_first = true
    for cand in input:iter() do
        -- 首候选提交提示
        if is_first and no_commit then
            apply_commit_hint(cand, cached.hint_text)
        end
        is_first = false
        
        -- 单字模式过滤和提示处理
        if not is_danzi_mode or is_danzi_candidate(cand) then
            if show_hint then
                hint_optimized(cand, env)
            end
            yield(cand)
        end
    end
end

function M.init(env)
    local config = env.engine.schema.config
    
    -- 配置读取与缓存（保持原始功能）
    env.cached_s = config:get_string(CONFIG_KEYS.TOPUP_THIS) or ""
    env.cached_b = config:get_string(CONFIG_KEYS.TOPUP_WITH) or ""
    env.cached_hint_text = config:get_string(CONFIG_KEYS.HINT_TEXT) or DEFAULT_HINT_TEXT
    env.cached_reverse_lookup = ReverseLookup(config:get_string(CONFIG_KEYS.DICT) or "")
    
    -- 预转义字符（性能优化）
    env.cached_s_escaped = escape_pattern(env.cached_s)
    env.cached_b_escaped = escape_pattern(env.cached_b)
end

return { init = M.init, func = M.filter }

