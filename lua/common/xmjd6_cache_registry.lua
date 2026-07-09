-- 天行键 缓存注册表模块
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-02

local M = {}

local cleaners = {}
local order = {}

local function trim_name(name)
    if type(name) ~= "string" then return nil end
    name = name:match("^%s*(.-)%s*$")
    if name == "" then return nil end
    return name
end

function M.register(name, cleaner)
    name = trim_name(name)
    if not name or type(cleaner) ~= "function" then
        return false
    end
    if not cleaners[name] then
        order[#order + 1] = name
    end
    cleaners[name] = cleaner
    return true
end

function M.unregister(name)
    name = trim_name(name)
    if not name or not cleaners[name] then
        return false
    end
    cleaners[name] = nil
    return true
end

function M.clear_all()
    local cleared = 0
    local failed = 0
    for _, name in ipairs(order) do
        local cleaner = cleaners[name]
        if cleaner then
            local ok, did_clear = pcall(cleaner)
            if ok then
                if did_clear ~= false then
                    cleared = cleared + 1
                end
            else
                failed = failed + 1
            end
        end
    end
    collectgarbage("collect")
    return cleared, failed
end

function M.names()
    local names = {}
    for _, name in ipairs(order) do
        if cleaners[name] then
            names[#names + 1] = name
        end
    end
    return names
end

return M
