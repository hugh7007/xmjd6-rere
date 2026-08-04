-- eng_quick_exclude.lua
-- i 前缀排除表公共模块：从 xmjd6.cizu.dict.yaml 读取以 i 开头的编码词条。
-- eng_quick_processor.lua 和 eng_quick.lua 共用此模块，避免重复加载。

local M = {}

local PREFIX = "i"
local exclude_set = nil

local function get_exclude_path()
    if not rime_api or not rime_api.get_user_data_dir then return nil end
    local ok, dir = pcall(rime_api.get_user_data_dir)
    if not ok or not dir or dir == "" then return nil end
    return dir .. "/xmjd6.cizu.dict.yaml"
end

local function load_exclude_set()
    local path = get_exclude_path()
    if not path then return {} end
    local f = io.open(path, "r")
    if not f then return {} end

    local set = {}
    for line in f:lines() do
        if line and line:sub(1, 1) ~= "#" and line:sub(1, 3) ~= "---" and line:sub(1, 3) ~= "..." then
            local tab_pos = line:find("\t")
            if tab_pos then
                local code = line:sub(tab_pos + 1)
                code = code:gsub("%s+$", "")
                if code:sub(1, 1) == PREFIX and #code >= 2 then
                    local rest = code:sub(2)
                    if rest:match("^[%a]+$") then
                        set[rest] = true
                    end
                end
            end
        end
    end
    f:close()
    return set
end

-- 检查 query（去掉 i 前缀后的部分）是否命中排除表
function M.is_excluded(query)
    if not query or query == "" then return false end
    if not exclude_set then
        exclude_set = load_exclude_set()
    end
    local first_segment = query:match("^([^']+)")
    if not first_segment then return false end
    return exclude_set[first_segment] == true
end

-- 强制重新加载
function M.reload()
    exclude_set = load_exclude_set()
end

return M
