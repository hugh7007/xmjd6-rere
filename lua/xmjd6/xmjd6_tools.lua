-- xmjd6_tools.lua
-- "=" 引导的小工具集（与计算器/数字大写/日历查询共用 = 前缀，互不冲突）：
--   =?            显示需要输入码触发的功能帮助候选
--                 （- / = 翻页；空格执行高亮功能；数字 1~9 直选当页功能，见 help_panel.lua）
--   =uuid         生成 UUID v4（小写/大写候选）
--   =pw / =pw20   生成随机密码（默认 16 位，可指定 8~64 位，候选含符号/纯字母数字两种）
--   =mem          查看当前 Lua 堆内存与已注册缓存数（配合 iOS 内存调试）
--   =memc         立即释放所有已注册缓存并 GC，显示清理前后内存对比
--   =1718160000   10/13 位 Unix 时间戳转日期时间（13 位按毫秒解析）

local mem_cleaner = require("xmjd6.mem_cleaner")
local help_items = require("xmjd6.help_items")
local HELP_ITEMS = help_items.items

math.randomseed(os.time())

local unpack_fn = table.unpack or unpack

local function uuid4()
    local b = {}
    for i = 1, 16 do b[i] = math.random(0, 255) end
    -- 不用位运算符以兼容 Lua 5.1：(x & 0x0f)|0x40 == x%16+64，(x & 0x3f)|0x80 == x%64+128
    b[7] = b[7] % 16 + 64   -- version 4
    b[9] = b[9] % 64 + 128  -- RFC 4122 variant
    return string.format(
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        unpack_fn(b))
end

-- 密码字符集去掉易混淆的 0 O 1 l I
local PW_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
local PW_SYMBOLS = "!@#$%^&*-_+?"

local function gen_password(len, with_symbol)
    local pool = PW_CHARS .. (with_symbol and PW_SYMBOLS or "")
    local out = {}
    for i = 1, len do
        local k = math.random(1, #pool)
        out[i] = pool:sub(k, k)
    end
    return table.concat(out)
end

-- 取某时间戳所在「本地日历日」的零点时间戳，用于按日期（而非按 86400 秒）算天数差
local function day_start(t)
    local d = os.date("*t", t)
    d.hour, d.min, d.sec = 0, 0, 0
    return os.time(d)
end

-- 读菜单页大小（menu/page_size，默认 5）；weasel 不保证调用 init，故惰性求值并缓存
local function page_size_of(env)
    if env.help_page_size then
        return env.help_page_size
    end
    local n = 5
    pcall(function()
        local v = env.engine.schema.config:get_int("menu/page_size")
        if v and v > 0 then n = v end
    end)
    env.help_page_size = n
    return n
end

local function tools(input, seg, env)
    if input == "=?" then
        -- 翻页：- / =（key_binder 已绑定 Page_Up / Page_Down，原生翻页）
        -- 每页第一条的说明尾带【第n页/共m页】标记；空格/数字直选执行功能由 help_panel.lua 接管
        local ps = page_size_of(env)
        local pages = math.ceil(#HELP_ITEMS / ps)
        for i, item in ipairs(HELP_ITEMS) do
            local comment = item[2]
            if (i - 1) % ps == 0 then
                local pg = math.floor((i - 1) / ps) + 1
                comment = comment .. "｜【第" .. pg .. "页/共" .. pages .. "页】"
            end
            yield(Candidate("tools", seg.start, seg._end, item[1], comment))
        end
        return
    end

    if input == "=uuid" then
        local u = uuid4()
        yield(Candidate("tools", seg.start, seg._end, u, "UUID"))
        yield(Candidate("tools", seg.start, seg._end, u:upper(), "UUID大写"))
        return
    end

    local pw_len = input:match("^=pw(%d*)$")
    if pw_len then
        local len = tonumber(pw_len) or 16
        if len < 8 then len = 8 elseif len > 64 then len = 64 end
        yield(Candidate("tools", seg.start, seg._end, gen_password(len, true), "密码·含符号"))
        yield(Candidate("tools", seg.start, seg._end, gen_password(len, false), "密码·字母数字"))
        return
    end

    if input == "=mem" or input == "=memc" then
        local before = collectgarbage("count")
        if input == "=memc" then
            mem_cleaner.release_all()
            local after = collectgarbage("count")
            yield(Candidate("tools", seg.start, seg._end,
                string.format("已清理 %.2f MB", (before - after) / 1024),
                string.format("%.2f → %.2f MB", before / 1024, after / 1024)))
            return
        end
        local n = 0
        for _ in pairs(mem_cleaner.releasers) do n = n + 1 end
        yield(Candidate("tools", seg.start, seg._end,
            string.format("Lua堆 %.2f MB", before / 1024), _VERSION))
        yield(Candidate("tools", seg.start, seg._end,
            string.format("已注册缓存 %d 个", n), "可被sentinel释放"))
        return
    end

    -- 10/13 位 Unix 时间戳 → 日期时间
    local digits = input:match("^=(%d+)$")
    if digits and (#digits == 10 or #digits == 13) then
        local ts = tonumber(#digits == 13 and digits:sub(1, 10) or digits)
        local ok, datestr = pcall(os.date, "%Y-%m-%d %H:%M:%S", ts)
        if ok and type(datestr) == "string" then
            local ms = (#digits == 13) and ("." .. digits:sub(11)) or ""
            -- 按本地日历日期算天数差（不能用 (ts-now)/86400 取整：同一天但更早的时刻会被误判为「1天前」）
            local diff_days = math.floor((day_start(ts) - day_start(os.time())) / 86400 + 0.5)
            local rel
            if diff_days == 0 then rel = "今天"
            elseif diff_days > 0 then rel = diff_days .. "天后"
            else rel = (-diff_days) .. "天前" end
            yield(Candidate("tools", seg.start, seg._end, datestr .. ms, "时间戳·" .. rel))
            yield(Candidate("tools", seg.start, seg._end,
                os.date("%Y年%m月%d日 %H:%M", ts), rel))
        end
        return
    end
end

return tools
