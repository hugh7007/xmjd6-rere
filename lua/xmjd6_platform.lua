-- Rime 平台兼容工具
-- 统一处理 librime API 差异、候选刷新、分段标签等跨平台能力。
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-06-04

local M = {}

local type = type
local string_find = string.find
local string_lower = string.lower
local string_match = string.match

function M.rime_api_string(name)
    if type(rime_api) ~= "table" then return "" end
    local fn = rime_api[name]
    if type(fn) ~= "function" then return "" end
    local ok, value = pcall(fn)
    if ok and type(value) == "string" then return string_lower(value) end
    return ""
end

function M.detect()
    local code = M.rime_api_string("get_distribution_code_name")
    local name = M.rime_api_string("get_distribution_name")
    local dir = M.rime_api_string("get_user_data_dir")
    local marker = code .. " " .. name .. " " .. dir
    local platform = {
        code = code,
        name = name,
        user_data_dir = dir,
        marker = marker,
    }

    if string_find(marker, "weasel", 1, true) then
        platform.kind = "weasel"
    elseif string_find(marker, "squirrel", 1, true) then
        platform.kind = "squirrel"
    elseif string_find(marker, "fcitx", 1, true) then
        platform.kind = "fcitx"
    elseif string_find(marker, "ibus", 1, true) then
        platform.kind = "ibus"
    else
        platform.kind = "unknown"
    end
    return platform
end

function M.should_defer_topup(config, ctx)
    if ctx and ctx:get_option("xmjd6_topup_defer") then return true end
    local override = config and config:get_string("xmjd6/platform/topup_defer")
    if override == "always" then return true end
    return false
end

function M.refresh(ctx, config)
    if not ctx or type(ctx.refresh_non_confirmed_composition) ~= "function" then
        return false
    end
    local override = config and config:get_string("xmjd6/platform/enable_refresh")
    if override == "false" or override == "0" or override == "no" then
        return false
    end
    local ok = pcall(function()
        ctx:refresh_non_confirmed_composition()
    end)
    return ok
end

function M.safe_connect(notifier, callback)
    if not notifier or type(callback) ~= "function" then return nil end
    local ok, conn = pcall(function()
        return notifier:connect(callback)
    end)
    if ok then return conn end
    return nil
end

function M.safe_disconnect(conn)
    if not conn then return end
    if type(conn.disconnect) == "function" then
        pcall(function() conn:disconnect() end)
    end
end

function M.safe_key_bool(key_event, name)
    if not key_event or type(key_event[name]) ~= "function" then return false end
    local ok, value = pcall(function()
        return key_event[name](key_event)
    end)
    return ok and value == true
end

function M.clean_repr(raw_key)
    if type(raw_key) ~= "string" then return raw_key end
    return string_match(raw_key, "^[Ss]hift%+(.*)") or raw_key
end

return M
