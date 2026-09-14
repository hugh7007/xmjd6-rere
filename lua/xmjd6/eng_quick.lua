-- eng_quick_exclude.lua
-- i 前缀排除表公共模块：从下方 EXCLUDE_FILES 中列出的词典读取以 i 开头的编码词条
-- （取每行 Tab 之后为编码，格式为「词条\t编码」）。
-- eng_quick_processor.lua 和 eng_quick.lua 共用此模块，避免重复加载。
-- 如需新增排除来源，在 EXCLUDE_FILES 表中加一行文件名即可。
--
-- 维护两张表：
--   exclude_set  所有 i 前缀码（去掉 i 后余下的部分）
--   cjk_set      其中「词条含非 ASCII 字符（汉字/部首/笔画）」的子集
--                如 io→金钅⺗㣺、ii→〢艹刂、iu→扌手リ
-- 含汉字的码必须完全放行给主词典（is_pass_through），否则会被 i 英文模式抢走，
-- 导致这些部首/笔画永远打不出来。

local EXCLUDE = {}

local PREFIX = "i"
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
-- 以下为 i 前缀英文 translator（原 eng_quick.lua 主体，2026-09-14 合并）：
--   exclude 表不再单独成文件；eng_quick_processor 改用 require(...).exclude。
-- ════════════════════════════════════════════════════════════════

-- eng_quick.lua
-- i 前缀快捷英文字母输入模式（无词库，纯字母上屏）。
-- translator 部分：在 eng_quick_mode 分段内生成候选。
--
-- affix_segmentor@eng_quick_mode 会去掉 i 前缀，translator 收到的 input 不含 i。
-- 例如用户输入 itea → 分段 input 为 tea → 候选显示 tea
-- 用户输入 igood'tea → 分段 input 为 good'tea → 候选显示 good tea
--
-- 排除表：命中时候选显示保留 i 前缀（如 input=ma → 候选显示 ima）。
--   排除表逻辑在 eng_quick_exclude 公共模块中，两个文件共用。
--
-- 含汉字的 i 码（io/ii/iu/ia …）：完全不出候选，交回主词典，
--   否则 金钅⺗㣺、〢艹刂、扌手リ 这类部首笔画永远被英文候选压住。

local M = {}

local SEP = "'"
local PREFIX = "i"

local exclude = EXCLUDE

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
    if exclude.is_pass_through(input) then
        return
    end

    -- 排除表：命中时候选显示 i + 排除词
    if exclude.is_excluded(input) then
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

M.func = translator

-- [0914] 暴露给 eng_quick_processor（require("xmjd6.eng_quick").exclude）
M.exclude = EXCLUDE
return M
