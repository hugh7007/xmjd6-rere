-- 优化版select_character  来源：@浮生 https://github.com/wzxmer/rime-txjx
local function utf8_safe_sub(s, i, j)
    if type(s) ~= "string" or s == "" then return "" end
    
    i = i or 1
    j = j or -1

    -- 获取UTF-8长度并处理负索引
    local len = utf8.len(s) or 0
    if len == 0 then return "" end

    i = (i < 0) and math.max(len + 1 + i, 1) or math.min(i, len)
    j = (j < 0) and math.max(len + 1 + j, 1) or math.min(j, len)

    -- 边界检查
    if j < i then return "" end

    -- 获取字节偏移
    local byte_start = utf8.offset(s, i)
    local byte_end = utf8.offset(s, j + 1)

    if byte_start then
        return byte_end and s:sub(byte_start, byte_end - 1) or s:sub(byte_start)
    end
    return ""
end

local function select_character(key, env)
    local engine = env.engine
    local context = engine.context
    local config = engine.schema.config

    -- 配置读取优化（带默认值）
    local first_key = config:get_string('key_binder/select_first_character')
    local last_key = config:get_string('key_binder/select_last_character')

    -- 快速失败检查
    if not (first_key or last_key) or not context:has_menu() then
        return 2 -- kNoop
    end

    local selected = context:get_selected_candidate()
    if not selected or selected.text == "「" then
        return 2 -- kNoop
    end

    local key_repr = key:repr()
    local text = selected.text

    -- 执行选字逻辑
    if first_key and key_repr == first_key then
        engine:commit_text(utf8_safe_sub(text, 1, 1))
        context:clear()
        return 1 -- kAccepted
    elseif last_key and key_repr == last_key then
        engine:commit_text(utf8_safe_sub(text, -1, -1))
        context:clear()
        return 1 -- kAccepted
    end

    return 2 -- kNoop
end

return select_character
