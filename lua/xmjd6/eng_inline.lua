-- eng_inline.lua
-- 在 xmjd6 主方案中以 i 前缀引导英文单词输入。
-- 空码 i 仍由 repeat_history 处理（历史记录），不受影响。
-- i + 字母 → 去掉 i 前缀，查 english 词典，输出英文候选。
--
-- 实现方式：读取 english.dict.yaml 到内存缓存，前缀匹配。

local M = {}

local MAX_CANDS = 5         -- 单次候选上限（翻页时 Rime 会再次调用 translator 继续yield）
local CACHE_TTL = 30        -- 缓存有效期（秒）

local file_cache = nil
local file_cache_time = nil

local function get_dict_content()
    local now = os.time()
    if file_cache and file_cache_time and os.difftime(now, file_cache_time) < CACHE_TTL then
        return file_cache
    end
    local user_dir = rime_api.get_user_data_dir()
    local f = io.open(user_dir .. "/english.dict.yaml", "r")
    if not f then return nil end
    file_cache = f:read("*a")
    f:close()
    file_cache_time = now
    return file_cache
end

local function translator(input, seg, env)
    -- 只处理 i 前缀且后面有内容的情况
    if #input < 2 or input:sub(1, 1) ~= "i" then
        return
    end

    local raw_query = input:sub(2)

    -- 只处理纯字母查询
    if not raw_query:match("^[a-zA-Z]+$") then
        return
    end

    local query = raw_query:lower()
    local qlen = #query

    local content = get_dict_content()
    if not content then return end

    local yielded = 0

    -- 逐行扫描，前缀匹配 code 列
    for line in content:gmatch("[^\n]+") do
        if yielded >= MAX_CANDS then break end

        -- 跳过 yaml 元数据行
        if line:sub(1, 1) ~= "#" and line:sub(1, 3) ~= "---" and line:sub(1, 3) ~= "..." then
            local code, text = line:match("^([^\t]+)\t([^\t]*)")
            if code and text then
                -- 前缀匹配（大小写不敏感）
                if code:sub(1, qlen):lower() == query then
                    local cand = Candidate("eng", seg.start, seg._end, code, " " .. text)
                    cand.quality = 10000 - yielded
                    cand.preedit = raw_query  -- preedit 显示去掉 i 前缀的部分
                    yield(cand)
                    yielded = yielded + 1
                end
            end
        end
    end
end

M.func = translator

-- 接入统一清理
local has_cleaner, mem_cleaner = pcall(require, "xmjd6.mem_cleaner")
if has_cleaner then
    mem_cleaner.register(function()
        file_cache = nil
        file_cache_time = nil
    end)
end

return M
