-- xmjd6_tools.lua
-- "=" 引导的小工具集（与计算器/数字大写/日历查询共用 = 前缀，互不冲突）：
--   =?            显示需要输入码触发的功能帮助候选
--   =uuid         生成 UUID v4（小写/大写候选）
--   =pw / =pw20   生成随机密码（默认 16 位，可指定 8~64 位，候选含符号/纯字母数字两种）
--   =mem          查看当前 Lua 堆内存与已注册缓存数（配合 iOS 内存调试）
--   =memc         立即释放所有已注册缓存并 GC，显示清理前后内存对比
--   =1718160000   10/13 位 Unix 时间戳转日期时间（13 位按毫秒解析）

local mem_cleaner = require("xmjd6.mem_cleaner")

math.randomseed(os.time())

local unpack_fn = table.unpack or unpack

local HELP_ITEMS = {
    { "=?", "功能帮助：列出需要输入码触发的功能" },
    { "=??", "快符速查表：列出 ; 引导的快捷符号" },
    { "=tj", "打字统计：字数 / 码长 / 退格 / 速度" },
    { "rq", "日期：横线式 / 中文式 / 大写式 / 农历节气" },
    { "ej", "时间、日期时间、Unix 时间戳" },
    { "xq", "星期、周数、英文星期" },
    { "nl", "农历、干支、时辰" },
    { "dje", "纪念日 / 节日 / 节气倒计时" },
    { "=19910501", "日历查询：公历农历干支星期互转" },
    { "=uuid", "UUID v4（小写 / 大写）" },
    { "=pw / =pw24", "随机密码：默认16位，可指定8~64位" },
    { "=mem", "查看当前 Lua 堆内存与已注册缓存数" },
    { "=memc", "释放已注册缓存并执行 GC" },
    { "=1718160000", "Unix 时间戳转日期时间（10/13位）" },
    { "=1+1", "计算器：Lua 表达式、函数、链式调用" },
    { "=123", "数字 / 金额大写读法" },
    { "' + 整句编码", "连打模式：空格/顶功自动追加 ' 分隔，双空格上屏" },
    { "连打开 / 连打关", "在方案选单中控制空码 ' 是否进入整句连打" },
    { "'模式中再按 '", "分隔一简、不能顶功或容易歧义的前后编码" },
    { "有候选时按 /", "加工当前候选；连打模式中加工完整句子" },
    { "Ctrl+G / =wrap", "普通候选或最近历史的文本加工入口" },
    { "|", "辫子模式：用 ᥬ ᩤ 包裹当前候选" },
    { "=join/3", "合并最近3段上屏内容，可选顿号、逗号、空格或换行" },
    { "=rmb1234.56", "人民币金额大写；小数也可直接输入 =1234.56" },
    { "=255>16 / =16:ff>10", "二至三十六进制转换" },
    { "=5~3", "按位异或：候选含十进制、十六进制、二进制" },
    { "=10km>mi", "长度：mm/cm/m/km/in/ft/yd/mi" },
    { "=1kg>lb", "重量：mg/g/kg/oz/lb" },
    { "=1024mb>gb", "数据容量：b/kb/mb/gb/tb（按1024换算）" },
    { "=100c>f", "温度：c/f/k" },
    { "'上几次输入'编码;", "动态自造词：把最近几次上屏内容加入该编码" },
    { "''词'编码;", "动态自造词：精确删除词+编码" },
    { "'''", "自造词管理：输入后列出全部，上下选中后按 ' 删除" },
    { "0", "动态调频：把第二/高亮候选提到首选" },
    { "=tp", "调频管理：输入后列出全部调频，上下选中后按 0 撤销" },
    { "coerr", "动态调频：查看 candidate_order.txt 解析错误" },
    { "\\abc123", "字符工具：数学斜体小写" },
    { "\\\\abc123", "字符工具：数学斜体大写" },
    { "\\\\\\abc", "字符工具：无衬线粗体" },
    { "&62fc", "Unicode 码点查字，候选含相邻码点" },
    { "打字后按 ?", "词库模糊搜索：按当前首选词查词库编码" },
    { "u + 全拼", "全拼反查键道编码" },
    { "v + 两分", "两分 / 拆字反查" },
    { "o + 编码", "GBK 全字集查询" },
}

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

local function tools(input, seg, env)
    if input == "=?" then
        for _, item in ipairs(HELP_ITEMS) do
            yield(Candidate("tools", seg.start, seg._end, item[1], item[2]))
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
