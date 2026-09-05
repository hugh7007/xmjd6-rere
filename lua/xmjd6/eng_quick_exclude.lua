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

local M = {}

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
function M.is_excluded(query)
    local seg = first_segment(query)
    if not seg then return false end
    ensure_loaded()
    return exclude_set[seg] == true
end

-- 命中排除表、但词库里对应的是汉字/部首/笔画 → 必须放行给主词典。
-- 引擎侧由 recognizer 的 eng_quick_mode 负向预查把这类码排除出 i 英文分段，
-- 这里再让 translator / processor 主动让路，避免空格、回车被拦截成上屏 i+码。
function M.is_pass_through(query)
    local seg = first_segment(query)
    if not seg then return false end
    ensure_loaded()
    return cjk_set[seg] == true
end

-- 强制重新加载
function M.reload()
    exclude_set, cjk_set = load_exclude_set()
end

return M
