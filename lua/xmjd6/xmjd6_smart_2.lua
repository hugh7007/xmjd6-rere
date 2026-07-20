-- 分号和撇号都属于编码输入：
--   ; 继续作为编码/快捷符号引导；
--   ' 交给 speller/delimiter：空码时进入整句模式，整句中继续作为编码分隔符。
-- 保留这个处理器占位，避免改变后续 processors 的配置索引。
local kNoop = 2

local function processor(key_event, env)
    return kNoop
end

return { func = processor }
