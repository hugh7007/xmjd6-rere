-- 英文上屏自动加空格过滤器
-- 若候选内容为纯英文（ASCII字母、数字、常见英文符号），则前后加空格
-- 受 eng_space 开关控制

local function is_english(text)
    -- 纯ASCII字母/数字/下划线/连字符/点，且至少含一个字母
    return text:match("^[%a%d%._%-]+$") and text:match("%a") ~= nil
end

local function filter(input, env)
    local context = env.engine.context
    local on = context:get_option("eng_space")
    if not on then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local is_first = true
    for cand in input:iter() do
        if is_first and is_english(cand.text) then
            yield(Candidate(cand.type, cand.start, cand._end,
                " " .. cand.text .. " ",
                cand:get_genuine().comment))
        else
            yield(cand)
        end
        is_first = false
    end
end

return filter
