-- dict_search_trigger.lua
-- 拦截 ? 键：取当前首选文本，在指定词库中模糊搜索，把结果存全局
-- 然后在 input 末尾追加 ?，让 recognizer 识别为 dict_search 段，交给 lua_translator 显示
--
-- 实现说明：流式扫描——每次搜索逐块读词库文件、边读边匹配、用完即扔，
-- 词条不在内存常驻（iOS 键盘扩展友好，jetsam 零负担）。
-- 代价是每次按 ? 都重读文件：18 个词库约 106 万词条，实测典型 50~300ms，
-- 最坏（无命中需扫完全部文件）约 650ms（Mac）；凑满 MAX_CANDIDATES 即提前终止。

local mem_cleaner = require("xmjd6.mem_cleaner")

local kAccepted = 1
local kNoop = 2

-- sentinel keycode: XK_VoidSymbol = 0xFFFFFF
-- 由 iOS 端 RimeEngine.cleanupMemory() 在键盘收起时发送，统一释放所有 Lua 缓存。
-- VoidSymbol 是 X11 标准 noop keysym，正常 processor 都不会处理它。
local CLEAR_CACHE_KEYCODE = 0xFFFFFF

-- 要搜索的词库列表：要禁用某个词库，在它前面加 -- 注释掉即可
local DICT_FILES = {
    -- ============ 最初的 3 个核心词库 ============
    "xkjd6.tangshi.dict.yaml",    -- 唐诗 (3.5k 行)
    "xkjd6.jisuanji.dict.yaml",   -- 计算机 (73 行)
    "xkjd6.yixue.dict.yaml",      -- 医学 (29.6k 行)
    "xkjd6.liuxing.dict.yaml",    -- 流行 (29k 行)
    "xkjd6.qiche.dict.yaml",      -- 汽车 (128 行)
    "xkjd6.kaifa.dict.yaml",      -- 开发 (134 行)

    -- ============ xkjd6.* 其他词库 ============
    "xkjd6.changyong.dict.yaml",  -- 常用 (859 行)
    "xkjd6.hanyu.dict.yaml",      -- 汉语 (33 行)

    "xkjd6.lanlao.dict.yaml",     -- 兰佬 (104k 行)
    "xkjd6.lanlao2.dict.yaml",    -- 兰佬2 (406k 行 ★大)
    "xkjd6.liangzi.dict.yaml",    -- 量子 (190k 行 ★大)

    "xkjd6.ssb1.dict.yaml",       -- 声笔笔 (22 行)
    "xkjd6.wanne.dict.yaml",      -- 离谱诗词 (1.9k 行)
    -- "xkjd6.yingwen.dict.yaml",    -- 英文 (135 行)
    "xkjd6.yinyang.dict.yaml",    -- 阴阳 (129 行)

    -- ============ xmjd6.* 词库 ============
    -- "xmjd6.buchong.dict.yaml",    -- 补充 (272 行)
    -- "xmjd6.chaojizici.dict.yaml", -- 超级字词 (428 行)
    -- "xmjd6.cizu.dict.yaml",       -- 词组 (121k 行 ★大)
    -- "xmjd6.cx.dict.yaml",         -- 反查 (41k 行)
    -- "xmjd6.danzi.dict.yaml",      -- 单字 (33k 行)
    -- "xmjd6.en.dict.yaml",      -- 英文 (569k 行 ★★超大，默认关闭；中文搜索意义不大)
    -- "xmjd6.extended.dict.yaml",   -- 扩展 (126 行)
    "xmjd6.fjcy.dict.yaml",       -- 附加词语 (294k 行 ★大)
    -- "xmjd6.fuhao.dict.yaml",      -- 符号 (180 行)
    -- "xmjd6.gbk.dict.yaml",        -- GBK (24k 行)
    "xmjd6.lianjie.dict.yaml",    -- 链接 (17 行)
    "xmjd6.user.dict.yaml",       -- 用户 (763 行)
    -- "xmjd6.wxw.dict.yaml",        -- 525声笔笔词组 (636 行)
    -- "xmjd6.wxwdanzi.dict.yaml",   -- 声笔笔单字 (614 行)
    -- "xmjd6.yingwen.dict.yaml",    -- 英文 (132 行)
    "xmjd6.zidingyi.dict.yaml",   -- 自定义 (249 行)
}

local MAX_CANDIDATES = 200
local CHUNK_SIZE = 262144 -- 256KB/块：块内用 C 层 string.find 扫描，远快于逐行迭代

if not _G.__dict_search_state then
    _G.__dict_search_state = {
        candidates = nil, -- 最近一次搜索结果（dict_search.lua 读取），最多 MAX_CANDIDATES 条
        query = nil,
    }
end

-- 流式实现本身无常驻缓存；注册清理是为了 sentinel 到达时顺手放掉上次的搜索结果
mem_cleaner.register(function()
    local state = _G.__dict_search_state
    if state then
        state.candidates = nil
        state.query = nil
    end
end)

-- 在一个由完整行组成的文本块内收集命中词条。
-- 词库头部(yaml 元数据)无需特意跳过：没有 Tab 两列结构的行通不过格式校验。
local function scan_block(block, query, matches, n)
    local pos = 1
    while n < MAX_CANDIDATES do
        local s = string.find(block, query, pos, true)
        if not s then break end
        -- 回找行首、行尾，取出完整词条行
        local line_start = s
        while line_start > 1 and block:byte(line_start - 1) ~= 10 do
            line_start = line_start - 1
        end
        local line_end = string.find(block, "\n", s, true) or (#block + 1)
        local line = block:sub(line_start, line_end - 1)
        local text, code = line:match("^([^\t]+)\t([^\t]+)")
        -- 确认命中落在词条文本部分（而不是编码部分），并过滤注释行
        if text and code and not text:match("^#") and string.find(text, query, 1, true) then
            n = n + 1
            matches[n] = { text = text, code = code }
        end
        pos = line_end + 1 -- 跳到下一行，同一行内多次命中只取一次
    end
    return n
end

local function scan_file(f, query, matches, n)
    local tail = "" -- 上一块末尾的不完整行，拼到下一块开头，保证 query 命中不跨块
    while n < MAX_CANDIDATES do
        local block = f:read(CHUNK_SIZE)
        if not block then break end
        block = tail .. block
        local last_nl = block:match("()\n[^\n]*$")
        if last_nl then
            tail = block:sub(last_nl + 1)
            block = block:sub(1, last_nl)
        else
            -- 整块没有换行（单行超过 256KB 的病态情况）：当独立块处理
            tail = ""
        end
        n = scan_block(block, query, matches, n)
    end
    -- 文件末行可能没有换行符，残尾单独扫一次
    if tail ~= "" and n < MAX_CANDIDATES then
        n = scan_block(tail, query, matches, n)
    end
    return n
end

local function search(query)
    local matches = {}
    local n = 0
    local user_dir = rime_api.get_user_data_dir()
    local shared_dir = rime_api.get_shared_data_dir()
    for _, fname in ipairs(DICT_FILES) do
        -- 词库文件优先从 user_dir 读取（允许用户覆盖），
        -- 找不到时回退到 shared_dir（输入法发行版自带词库放在这里，例如 iOS App Group SharedData/Rime）
        local f = io.open(user_dir .. "/" .. fname, "r")
        if not f and shared_dir and shared_dir ~= "" then
            f = io.open(shared_dir .. "/" .. fname, "r")
        end
        if f then
            n = scan_file(f, query, matches, n)
            f:close()
        end
        if n >= MAX_CANDIDATES then break end
    end
    return matches
end

local function dict_search_trigger(key, env)
    if key:release() then return kNoop end

    -- 收到清缓存 sentinel：统一释放所有注册过的 Lua 缓存（反查库、
    -- lazy_simplifier 字典、懒加载的时间模块等），触发 Lua GC。
    -- 在没有 composing/menu 的状态下到达（键盘扩展收起前调用），不会影响用户输入。
    if key.keycode == CLEAR_CACHE_KEYCODE then
        mem_cleaner.release_all()
        return kAccepted
    end

    if key.keycode ~= 0x3f then return kNoop end

    local context = env.engine.context
    if not context:has_menu() then return kNoop end

    -- 只处理「键道码 + ?」的词库模糊搜索。
    -- Processor 收到 ? 时，? 还没进入 context.input；这里必须与
    -- schema 里的 dict_search: "^[a-z]+\\?$" 保持一致，只允许纯字母码。
    -- 否则输入 =? 时会被本 processor 抢先截获，拿 "=" 的符号候选去扫词库，
    -- 造成卡顿，并阻止 xmjd6_tools.lua 的 =? 帮助候选正常显示。
    local input = context.input or ""
    if not input:match("^[a-z]+$") then return kNoop end

    local selected = context:get_selected_candidate()
    if not (selected and selected.text and selected.text ~= "") then
        return kNoop
    end

    local query = selected.text
    -- utf8.len 对非法 UTF-8 返回 nil，or 0 防止 nil 比较报错
    if (utf8.len(query) or 0) < 1 then return kNoop end

    _G.__dict_search_state.candidates = search(query)
    _G.__dict_search_state.query = query

    context:push_input("?")
    return kAccepted
end

return dict_search_trigger
