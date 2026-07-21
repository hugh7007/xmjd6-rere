-- protected_codes.lua
-- 加载保护码列表，防止特定编码被顶功/空码回退截断。
-- 
-- 数据来源（按优先级）：
--   1. schema 配置 topup/protected_dicts（列表，每项是 dict 文件名，不含 .dict.yaml 后缀）
--   2. 回退到硬编码 xmjd6.zidingyi
--
-- 每个字典文件格式：text<TAB>code（code 为纯小写字母），# 开头为注释。
-- 文件不存在时跳过，不报错。

local M = {}

-- 模块级共享缓存
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

local function get_data_dir()
    if rime_api and rime_api.get_user_data_dir then
        local ok, dir = pcall(rime_api.get_user_data_dir)
        if ok and dir and dir ~= "" then return dir end
    end
    return "."
end

local function join_path(dir, name)
    if not dir or dir == "" then return name end
    local sep = (package.config or "/"):sub(1, 1)
    if sep ~= "/" then sep = "\\" end
    if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
        return dir .. name
    end
    return dir .. sep .. name
end

-- 从 schema 配置读取保护码字典列表
local function get_protected_dicts(config)
    local dicts = {}
    
    if config and config.get_list then
        local ok, list = pcall(function() return config:get_list("topup/protected_dicts") end)
        if ok and list then
            for i = 0, list:size() - 1 do
                local v = list:get_value_at(i)
                local name = v and (v.value or v:get_string())
                if name and name ~= "" then
                    dicts[#dicts + 1] = name
                end
            end
        end
    end
    
    if #dicts == 0 then
        dicts[1] = "xmjd6.zidingyi"
    end
    
    return dicts
end

-- load() 可无参数调用（回退默认字典），也可传 config 读取 schema 配置
function M.load(config)
    -- 简单缓存：如果已有缓存且 config 没变（或都为 nil），直接返回
    if cache then return cache end
    
    local codes = {}
    local data_dir = get_data_dir()
    local script_dir = get_script_dir()
    local dict_names = get_protected_dicts(config)
    
    for _, dict_name in ipairs(dict_names) do
        local path = join_path(data_dir, dict_name .. ".dict.yaml")
        local file = io.open(path, "r")
        
        if not file and script_dir then
            path = script_dir .. "../../" .. dict_name .. ".dict.yaml"
            file = io.open(path, "r")
        end
        
        if file then
            for line in file:lines() do
                local text, code = line:match("^([^\t]+)\t([a-z]+)")
                if text and code and is_ascii_text(text) then
                    codes[code] = true
                end
            end
            file:close()
        end
    end
    
    cache = codes
    return codes
end

return M
