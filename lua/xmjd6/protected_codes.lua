local M = {}

-- 模块级共享缓存：auto_fallback 与 topup_processor 都会 load()，
-- 只读一次文件、共用同一张表，避免每个组件实例各持一份
local cache = nil

local function get_script_dir()
    local source = debug.getinfo(1).source or ""
    return source:match("@?(.*/)")
end

local function is_ascii_text(text)
    if not text or text == "" then
        return false
    end
    for i = 1, #text do
        if text:byte(i) > 127 then
            return false
        end
    end
    return true
end

function M.load()
    if cache then return cache end
    local codes = {}
    local script_dir = get_script_dir()
    if not script_dir then
        return codes
    end

    local path = script_dir .. "../../xmjd6.zidingyi.dict.yaml"
    local file = io.open(path, "r")
    if not file then
        return codes
    end

    for line in file:lines() do
        local text, code = line:match("^([^\t]+)\t([a-z]+)")
        if text and code and is_ascii_text(text) then
            codes[code] = true
        end
    end

    file:close()
    cache = codes
    return codes
end

return M
