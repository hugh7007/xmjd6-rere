-- eng_quick.lua
-- i 前缀快捷英文字母输入模式（无词库，纯字母上屏）。
--
-- 【2026-09-20 合并说明】
--   本文件由 eng_quick.lua（translator + exclude 表）与 eng_quick_processor.lua
--   （processor）合并而来，原因是两者本就属于同一功能、共享同一张排除表。
--   合并后 schema 的两个挂载点都指向本模块：
--     - lua_processor@*xmjd6/eng_quick    → 取 M.func 当处理器（拦截空格/回车）
--     - lua_translator@*xmjd6/eng_quick   → 取 M.func 当翻译器（生成候选）
--   ⚠️ 引擎对两类组件都取 .func，所以分别导出 M.processor / M.translator，
--      而 M.func 保留为 translator（兼容旧挂载与既有习惯），processor 走 .processor。
--      schema 里 processor 那行请写成：lua_processor@*xmjd6/eng_quick@processor
--
-- ════════════════════════════════════════════════════════════════
-- 第一部分：排除表（原 eng_quick_exclude 公共模块）
-- ════════════════════════════════════════════════════════════════
-- 从 EXCLUDE_FILES 列出的词典读取以 i 开头的编码词条（每行 Tab 之后为编码）。
-- 维护两张表：
--   exclude_set  所有 i 前缀码（去掉 i 后余下的部分）
--   cjk_set      其中「词条含非 ASCII 字符（汉字/部首/笔画）」的子集
--                如 io→金钅⺗㣺、ii→〢艹刂、iu→扌手リ
-- 含汉字的码必须完全放行给主词典（is_pass_through），否则会被 i 英文模式抢走，
-- 导致这些部首/笔画永远打不出来。

local M = {}

local PREFIX = "i"
local SEP = "'"

local kAccepted = 1
local kNoop = 2

-- keycode 常量（跨平台）
local KEY_SPACE = 32    -- 0x20
local KEY_RETURN = 13   -- 0x0d

local exclude_set = nil
local cjk_set = nil

-- 排除表来源词典（位于 Rime 用户目录下）
local EXCLUDE_FILES = {
    "xmjd6.cizu.dict.yaml",
    "xmjd6.wxw.dict.yaml",
    "xmjd6.user.dict.yaml",
}

local function get_exclude_paths()
    if not rime_api or not rime_api.get_user_data_dir then return {} end
    local ok, dir = pcall(rime_api.get_user_data_dir)
    if not ok or not dir or dir == "" then return {} end
    local paths = {}
    for _, name in ipairs(EXCLUDE_FILES) do
        table.insert(paths, dir .. "/" .. name)
    end
    return paths
end

-- 判断词条是否含非 ASCII 字符（UTF-8 多字节即命中，含 CJK 扩展区 4 字节字）
local function is_cjk_entry(text)
    return text and text:find("[\128-\255]") ~= nil
end

local function load_exclude_set()
    local paths = get_exclude_paths()
    local set, cjk = {}, {}
    for _, path in ipairs(paths) do
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                if line and line:sub(1, 1) ~= "#" and line:sub(1, 3) ~= "---" and line:sub(1, 3) ~= "..." then
                    local tab_pos = line:find("\t")
                    if tab_pos then
                        local text = line:sub(1, tab_pos - 1)
                        local field = line:sub(tab_pos + 1):match("^([^\t]+)")
                        if field then
                            local code = field:gsub("%s+$", "")
                            if code:sub(1, 1) == PREFIX and #code >= 2 then
                                local rest = code:sub(2)
                                if rest:match("^[%a]+$") then
                                    set[rest] = true
                                    if is_cjk_entry(text) then
                                        cjk[rest] = true
                                    end
                                end
                            end
                        end
                    end
                end
            end
            f:close()
        end
    end
    return set, cjk
end

local function ensure_loaded()
    if not exclude_set or not cjk_set then
        exclude_set, cjk_set = load_exclude_set()
    end
end

-- 取 query 的第一个分段（' 之前的部分）
local function first_segment(query)
    if not query or query == "" then return nil end
    return query:match("^([^']+)")
end

local EXCLUDE = {}

-- 检查 query（去掉 i 前缀后的部分）是否命中排除表
function EXCLUDE.is_excluded(query)
    local seg = first_segment(query)
    if not seg then return false end
    ensure_loaded()
    return exclude_set[seg] == true
end

-- 命中排除表、但词库里对应的是汉字/部首/笔画 → 必须放行给主词典。
-- 引擎侧由 recognizer 的 eng_quick_mode 负向预查把这类码排除出 i 英文分段，
-- 这里再让 translator / processor 主动让路，避免空格、回车被拦截成上屏 i+码。
function EXCLUDE.is_pass_through(query)
    local seg = first_segment(query)
    if not seg then return false end
    ensure_loaded()
    return cjk_set[seg] == true
end

-- 强制重新加载
function EXCLUDE.reload()
    exclude_set, cjk_set = load_exclude_set()
end

-- ════════════════════════════════════════════════════════════════
-- 第二部分：translator（原 eng_quick.lua 主体）
-- ════════════════════════════════════════════════════════════════
-- affix_segmentor@eng_quick_mode 会去掉 i 前缀，translator 收到的 input 不含 i。
-- 例如用户输入 itea → 分段 input 为 tea → 候选显示 tea
-- 用户输入 igood'tea → 分段 input 为 good'tea → 候选显示 good tea
--
-- 排除表：命中时候选显示保留 i 前缀（如 input=ma → 候选显示 ima）。
-- 含汉字的 i 码（io/ii/iu/ia …）：完全不出候选，交回主词典。

local function to_display(input)
    if not input or input == "" then return "" end
    local s = input:gsub(SEP .. "$", "")
    return s:gsub(SEP, " ")
end

local function is_valid_query(query)
    return query and query:match("^[%a']+$") ~= nil
end

local function translator(input, seg, env)
    if not seg:has_tag("eng_quick_mode") then
        return
    end

    if not is_valid_query(input) then
        return
    end

    local display = to_display(input)
    if display == "" then return end

    -- 含汉字的 i 码（io→金钅⺗㣺、ii→〢艹刂、iu→扌手リ）：直接让路给主词典
    if EXCLUDE.is_pass_through(input) then
        return
    end

    -- 排除表：命中时候选显示 i + 排除词
    if EXCLUDE.is_excluded(input) then
        local full = PREFIX .. display
        local cand = Candidate("eng_quick", seg.start, seg._end, full, "")
        cand.quality = 10000
        cand.preedit = full
        yield(cand)
        return
    end

    local cand = Candidate("eng_quick", seg.start, seg._end, display, "")
    cand.quality = 10000
    cand.preedit = display
    yield(cand)
end

-- ════════════════════════════════════════════════════════════════
-- 第三部分：processor（原 eng_quick_processor.lua 主体）
-- ════════════════════════════════════════════════════════════════
-- 行为：
--   i + good + 空格 → 空格作为单词分隔符，追加 ' 继续输入（igood'）
--   双空格          → 上屏整句（good tea）
--   回车            → 上屏整句（good tea）
--   i 空码          → 不拦截，express_editor 上屏 i 字母
--
-- 排除表：命中时上屏保留 i 前缀（如 ima → 上屏 ima，而非 ma）。
-- 空格/回车均通过 keycode 判断，兼容手机端。
--
-- 含汉字的 i 码（io/ii/iu/ia …）：空格与回车一律不拦截，
--   交回主词典的选字/顶功流程，否则会被上屏成 i+码 的字面量。

local function to_commit(input)
    if not input or input == "" then return "" end
    local s = input
    if s:sub(1, #PREFIX) == PREFIX then
        s = s:sub(#PREFIX + 1)
    end
    s = s:gsub(SEP .. "$", "")
    return s:gsub(SEP, " ")
end

local function is_eng_quick_input(input)
    return input and #input >= #PREFIX + 1 and input:sub(1, #PREFIX) == PREFIX
end

-- 判断是否空格键（兼容 repr 和 keycode）
local function is_space(key)
    local repr = key:repr()
    if repr == "space" then return true end
    -- fallback: keycode 32
    local ok, code = pcall(key.keycode, key)
    if ok and code == KEY_SPACE then return true end
    return false
end

-- 判断是否回车键（兼容 repr 和 keycode）
local function is_return(key)
    local repr = key:repr()
    if repr == "Return" or repr == "Lock+Return" then return true end
    local ok, code = pcall(key.keycode, key)
    if ok and code == KEY_RETURN then return true end
    return false
end

local function processor(key, env)
    if not key or (key.release and key:release()) then
        return kNoop
    end
    if key:ctrl() or key:alt() or key:super() then
        return kNoop
    end

    local is_sp = is_space(key)
    local is_ret = is_return(key)
    if not is_sp and not is_ret then
        return kNoop
    end

    local ctx = env.engine.context
    local input = ctx.input or ""

    if not is_eng_quick_input(input) then
        return kNoop
    end

    local query = input:sub(#PREFIX + 1)
    if not is_valid_query(query) then
        return kNoop
    end

    -- 含汉字的 i 码（io→金钅⺗㣺、ii→〢艹刂、iu→扌手リ）：不拦截，交给主词典
    if EXCLUDE.is_pass_through(query) then
        return kNoop
    end

    -- 排除表：命中时空格和回车都直接上屏 i + 排除词
    if EXCLUDE.is_excluded(query) then
        local clean_query = query:gsub(SEP .. "$", "")
        local text = PREFIX .. clean_query:gsub(SEP, " ")
        env.engine:commit_text(text)
        ctx:clear()
        return kAccepted
    end

    if is_sp then
        local last_char = input:sub(-1)
        if last_char == SEP then
            -- 双空格：上屏整句
            local text = to_commit(input)
            if text and text ~= "" then
                env.engine:commit_text(text)
                ctx:clear()
                return kAccepted
            end
            return kNoop
        else
            -- 单空格：追加分隔符
            ctx.input = input .. SEP
            return kAccepted
        end
    end

    if is_ret then
        local text = to_commit(input)
        if text and text ~= "" then
            env.engine:commit_text(text)
            ctx:clear()
            return kAccepted
        end
        return kNoop
    end

    return kNoop
end

-- ════════════════════════════════════════════════════════════════
-- 导出
-- ════════════════════════════════════════════════════════════════
-- ⚠️ librime-lua 对 processor / translator / filter 一律只取 .func，
--    无法靠导出名区分。同一个模块名被两类组件同时引用时，必须让 .func
--    自己按 env.name_space（schema 里 @ 后面的那段）分流。
--    schema 写法：
--      - lua_processor@*xmjd6/eng_quick@processor
--      - lua_translator@*xmjd6/eng_quick@translator
--    分流依据同时看 name_space 与入参类型（双保险）：
--      processor 的第 1 参是 KeyEvent 对象，带 :keycode() / :repr()
--      translator 的第 1 参是 string（输入串）
M.translator = translator
M.processor = processor

local function dispatch(a, b, c)
    -- a = key_event 或 input 字符串
    if type(a) == "string" then
        return translator(a, b, c)
    end
    -- 非字符串：判定为 processor 调用
    return processor(a, b)
end

M.func = dispatch

-- 保留显式别名，便于将来按名挂载或测试
M.exclude = EXCLUDE

return M
