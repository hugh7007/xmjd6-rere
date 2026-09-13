-- 挂载： xmjd6.schema.yaml
--   engine.translators 最后一行  - lua_translator@*xmjd6/input_statistics
--   engine.processors  第一行    - lua_processor@*xmjd6/key_counter
--
--  面板指令（全部以 = 触发，无 o 前缀别名）：
--  =tj  今日        =qb  全部        =yf  七日
--  =yy  卅日        =yn  本年        =jq  本设备
--  =wx  查某天 20260801（也支持 202608、2026、20260101t20260201）
--  =wk  查看（段位 + 皮肤）
--  =wkda/=wkdb      切段位（=[=wk]+[d]+[字母]）
--  =wkpa~=wkpi      切皮肤（=[=wk]+[p]+[字母]，字母按表内顺序对应编号）
--
-- 数据：LevelDB（input_stats/db_name，默认 stats），按「天 × 设备」聚合。
-- 计键：key_counter.lua 内存通道，每键 0 次磁盘 IO。
-- ══════════════════════════════════════
local AUTO_COMMIT_CODE_LEN = 4
-- 键道6 是「变长顶功」（topup_with: auvio;，min_length 4 / 单字 2），
-- 2 码简码、4 码单字、5~6 码全码都可能被下一个编码键顶上去，不存在固定的顶屏码长。
-- 这里保留非 0 值只用于启用「顶功 / 非顶」判定；新版面板已不再用它开关分布区。
--   四码固定顶屏方案 = 4     三码顶屏方案 = 3     全拼/双拼 = 0
local TOPUP_MODE = true
-- ══════════════════════════════════════
--★★★这里修改默认段位和皮肤，输入框里也可以用 =wk 系列指令随时切换，重新部署后恢复默认。
local DEFAULT_TITLE_THEME = "classic"
-- classic 原版段位（=wkda）    xiuxian 修仙段位（=wkdb）

--classic  🌱→🌟→🚀→💨→✨→⌨️
--   初学→渐入→运指→行云→出神→登峰
--xiuxian  🔥→⛰️→☀️→👁→🔮→👑→⌨️
--  炼气→筑基→金丹→元婴→化神→金仙→天人

local DEFAULT_SKIN = 1
-- a ▓▓▓▓▓░░░░░  原版皮肤
-- b ✭✭✭✭✭✩✩✩✩✩
-- c ★★★★★☆☆☆☆☆
-- d ●●●●●○○○○○
-- e ━━━━━┄┄┄┄┄
-- f ◆◆◆◆◆◇◇◇◇◇
-- g ■■■■■□□□□□
-- h ◆◆◆◆◆┄┄┄┄┄
-- ═════════════════════════════════════
-- （=wkp[a~h] 切皮肤、=wkd[a~b] 切段位，字母按上面列表顺序 1:1 对应，无需改这里）
-- 段位主题固定顺序（=wkd + 字母，从 a 开始逐个数）
local TITLE_THEME_ORDER = { "classic", "xiuxian" }
-- ═════════════════════════════════════
-- ═════════════════════════════════════
-- 【可修改】速度统计参数（改这里即可）
-- 改完保存 → 重新部署生效；若 schema 里配了 input_stats/xxx，则以 schema 为准。
-- ═════════════════════════════════════
-- 会话间隔（毫秒）：两次上屏间隔超过它 = 上一个会话结束，之后算新会话。
--   调大 → 均速更稳（想一下再打不会切断会话）；调小 → 更敏感。
--   范围：连续判定值 ~ 30000，默认 5000（5秒）
local AVERAGE_GAP_MS = 5000

-- 峰速窗口（毫秒）：一段「连续输入」累计到这么长，才结算出一个峰速样本。
--   调大 → 峰值更稳（更接近"持续速度"，短促爆发被抹平）；调小 → 更偏爆发力。
--   当前 10000（10 秒）。这个数字同时决定 UserDb 里峰速桶的后缀
--   （speed_peak_window_10s）——见下面的 peak_key_prefix()。
--   改这里会自动换后缀，并让 migrate_database 清掉旧后缀的桶，不会新旧混桶同算。
local PEAK_WINDOW_MS = 10000
-- 峰速窗口切断间隙（毫秒）：停顿超过它 = 这段输入结束，窗口结算（不足 PEAK_WINDOW_MS 则作废）。
--   必须与 AVERAGE_GAP_MS 取同一个值：全模块只允许存在一个「连续输入」的定义，
--   否则会出现「均速把这一段算作一个会话、峰速却把它切成两半」的口径打架。
--   注意与 PEAK_WINDOW_MS 语义不同：窗口 = 一段样本要多长，间隙 = 停多久算断。
local PEAK_GAP_MS = 5000

-- 连续输入判定（毫秒）：间隔超过它视为"不连续"输入（影响会话质量）。
--   范围：200 ~ 5000，默认 1000（1 秒）
local CONTINUOUS_GAP_MS = 1000

-- 最短会话（毫秒）：单次会话不足此时长不计入均速（排除碎片输入）。
--   范围：500 ~ 10000，默认 1000（1 秒）
local MINIMUM_AVERAGE_SESSION_MS = 1000

-- 最少总时长（毫秒）：所有会话累计不足此时长，均速显示 "--"。
--   范围：3000 ~ 120000，默认 15000（15 秒）
local MINIMUM_AVERAGE_TOTAL_MS = 15000

-- 速度统计单次上屏最大字数：超过不参与速度计算（排除粘贴大段文本）。
--   范围：1 ~ 10，默认 10
local MAX_SPEED_COMMIT_LENGTH = 10

-- 速度统计窗口（天）：=qb「全部」面板在这么长的窗口里算 均速 / 峰速 / 击键。
--   0 = 不限（用全部历史）。
--   **它只决定"统计多少天"，不会删除任何记录**——原始数据一直在 stats.userdb 里，
--   调大/调小随时能看回来。（旧注释写的"更早自动清理"是错的，代码里没有任何按日期删除的逻辑。）
--   注意：=tj/=yf/=yy/=yn/=wx 各有自己的区间，不受这个值影响。
--   范围：0 ~ 3650，默认 0（不限）
local SPEED_HISTORY_DAYS = 0

-- [0913] 峰速桶的键后缀，由窗口长度推导，保证「窗口长度」和「桶名」永远不会再漂移。
--   历史上这里就是漂的：窗口早改成 15 秒，桶名却一直写着 _10s，导致
--   光看键名根本对不上真实口径。现在窗口多长，桶名就写多长。
--   换窗口后旧后缀的桶会在 migrate_database() 里被清掉，新旧样本不会混在一个桶里算。
local function peak_key_prefix(window_ms)
    return string.format("speed_peak_window_%ds", math.floor(window_ms / 1000 + 0.5))
end
local userdb = require("xmjd6.userdb")
-- 击键器（可选，未挂载 processor 时会自动退回码长统计）
-- 这里拿到的只是「模块句柄」，用来看 key_counter 能不能用。**真正的数据共享不靠它**：
-- librime-lua 每个组件创建时都会清模块缓存，processor 与 translator 各自 require 一次，
-- 必然拿到两份不同的模块副本；key_counter.lua 把 pending / total_keys / commit_handler
-- 全部放在 _G.__xmjd6_key_counter_state 这张状态表里，所以哪份副本都行。
-- 取用顺序：_G 上的句柄 → require → dofile 兜底（部分发行版 package.path 不含用户目录 lua/）。
local key_counter = _G.__xmjd6_key_counter
local ok_key_counter = type(key_counter) == "table"
if not ok_key_counter then
    ok_key_counter, key_counter = pcall(require, "xmjd6.key_counter")
    if ok_key_counter and type(key_counter) ~= "table" then ok_key_counter = false end
end
-- 电脑 Rime 兼容：部分发行版的 librime-lua package.path 不含用户目录 lua/，
-- require 会失败（手机元书正常）。processor 按文件名加载不受影响、照常计数，
-- 但 ok_key_counter=false 会让指令键清理（reset）全部失效 → 指令键残留污染码长。
-- 兜底：require 失败时按绝对路径 dofile 加载同一份 key_counter.lua。
if not ok_key_counter and rime_api and rime_api.get_user_data_dir then
    local ok_dir, dir = pcall(rime_api.get_user_data_dir)
    if ok_dir and dir then
        if dir:sub(-1) ~= "/" then dir = dir .. "/" end
        ok_key_counter, key_counter = pcall(dofile, dir .. "lua/xmjd6/key_counter.lua")
        if ok_key_counter and type(key_counter) ~= "table" then ok_key_counter = false end
    end
end
key_counter = _G.__xmjd6_key_counter or key_counter
-- 模块私有数据库池：同名数据库共享包装器和生命周期。
local DB_POOL = {}

local SOFTWARE_NAME = rime_api.get_distribution_code_name()
local RECORD_SEPARATOR = " \t"
local STATS_C_MAX = 2147483000
local BATCH_INTERVAL = 5
local MAX_PENDING_CHARACTERS = 200
local STATISTICS_PREFIX = "statistics/"
local DAY_PREFIX = STATISTICS_PREFIX .. "day/"
local MIGRATION_KEY = "metadata/readable_statistics_migrated"
local DAY_FIELDS = {
    ["text/characters"]="characters",
    ["text/commits"]="commits",
    ["text/keystrokes"]="keystrokes",
    ["commit_length/1"]="length_1",
    ["commit_length/2"]="length_2",
    ["commit_length/3"]="length_3",
    ["commit_length/4"]="length_4",
    ["commit_length/5_plus"]="length_5_plus",
    ["text/code_len_without_space"]="code_len_without_space",
    ["text/auto_commits"]="auto_commits",
    ["text/backspaces"]="backspaces",
}
local LEGACY_FIELDS = {
    _len="text/characters",
    _cnt="text/commits",
    _code="text/keystrokes",
    _l1="commit_length/1",
    _l2="commit_length/2",
    _l3="commit_length/3",
    _l4="commit_length/4",
    _l_gt4="commit_length/5_plus",
}
-- [0813] 段位主题表（高→低：500万/100万/50万/10万/5万/1万/0）
-- classic（原版，默认）/ xiuxian（修仙）；/01 /02 切换
local TITLE_THEMES = {
    xiuxian = {
        {5000000, "☯️·天人合一"}, {1000000, "👑·金仙期"},
        {500000, "🔮·化神期"}, {100000, "👁·元婴期"},
        {50000, "☀️·金丹期"}, {10000, "⛰️·筑基期"},
        {0, "🔥·炼气期"},
    },
    classic = {
        {5000000, "⌨️·天人合一"}, {1000000, "⌨️·登峰造极"},
        {500000, "✨·出神入化"}, {100000, "💨·行云流水"},
        {50000, "🚀·运指如飞"}, {10000, "🌟·渐入佳境"},
        {0, "🌱·初学乍练"},
    },
}
-- 默认段位/皮肤在文件顶部配置区设置（DEFAULT_TITLE_THEME / DEFAULT_SKIN）
local TITLE_THEME_FILE = "lua/title_theme.txt"
local THEME_LABELS = { xiuxian = "修仙", classic = "原版" }

-- [0813] 进度条皮肤（=wk 查看，=wkp+字母 切换）
-- [0913] 新版面板只剩「比例」一条 6 格条，默认皮肤改成 ▰▱（与设计稿一致）；
--        旧的原版 ▓░▒ 挪到末位，仍可用 =wkp 切回。
local skinList = {
    { field = "▰", empty = "▱" }, -- 001 默认（新版面板比例条）
    { field = "✭", empty = "✩" }, -- 002（原22）
    { field = "★", empty = "☆" }, -- 003（原21）
    { field = "●", empty = "○", half = "◐" }, -- 004（原03）
    { field = "━", empty = "┄" }, -- 005（原02）
    { field = "◆", empty = "◇" }, -- 006（原06）
    { field = "■", empty = "□" }, -- 007（原04）
    { field = "◆", empty = "┄" }, -- 008（原16）
    { field = "▓", empty = "░", half = "▒" }, -- 009 旧原版皮肤（原001）
}
local SKIN_FILE = "lua/skin_word.txt"

local function read_text_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end
local function write_text_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end
local function user_data_dir()
    return rime_api.get_user_data_dir() .. "/"
end
local FINGER_STYLE_MAP = {
    pinyin="全拼", zrm="自然码", flypy="小鹤双拼", mspy="微软双拼",
    sogou="搜狗双拼", abc="智能ABC", ziguang="紫光双拼",
    pyjj="拼音加加", gbpy="国标双拼", zrlong="自然龙",
    hxlong="汉心龙", ltsp="蓝天双拼", lxsq="乱序17",
    sdpy="首道双拼", t9="九键",
}

-- [内联] 原 wanxiang.lua 的 get_input_method_type（万象公共库唯一依赖，已独立）
local INPUT_METHOD_MARKERS = {
    ["Ⅰ"] = "pinyin",   ["Ⅱ"] = "zrm",      ["Ⅲ"] = "flypy",    ["Ⅳ"] = "mspy",
    ["Ⅴ"] = "sogou",    ["Ⅵ"] = "abc",      ["Ⅶ"] = "ziguang",  ["Ⅷ"] = "pyjj",
    ["Ⅸ"] = "gbpy",     ["Ⅺ"] = "zrlong",   ["Ⅻ"] = "hxlong",   ["Ⅿ"] = "ltsp",
    ["Ⅼ"] = "lxsq",     ["Ⅽ"] = "dnsp",     ["Ⅾ"] = "sdpy",     ["ⅲ"] = "ⅲ",
    ["ⅱ"] = "t9",
}
local INPUT_METHOD_MARKER_ORDER = {
    "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ",
    "Ⅸ", "Ⅹ", "Ⅺ", "Ⅻ", "Ⅿ", "Ⅼ", "Ⅽ", "ⅱ",
}
local INPUT_METHOD_MD_MARKER = "ⅲ"
local function get_input_method_type(env)
    local config = env.engine.schema.config
    local algebra = config:get_list("speller/algebra")
    if not algebra then return "unknown" end
    local result_id = "unknown"
    local md = nil
    for i = 0, algebra.size - 1 do
        local value = algebra:get_value_at(i)
        local rule = value and value:get_string()
        if rule then
            if not md and rule:find(INPUT_METHOD_MD_MARKER, 1, true) then
                md = INPUT_METHOD_MD_MARKER
            end
            if result_id == "unknown" then
                for j = 1, #INPUT_METHOD_MARKER_ORDER do
                    local symbol = INPUT_METHOD_MARKER_ORDER[j]
                    if rule:find(symbol, 1, true) then
                        result_id = INPUT_METHOD_MARKERS[symbol]
                        break
                    end
                end
            end
            if result_id ~= "unknown" and md then break end
        end
    end
    if md then return result_id, md end
    return result_id
end

local function normalize_device_id(value)
    return tostring(value or ""):lower():gsub("[^0-9a-f]", ""):sub(1, 8)
end

local function is_device_id(value)
    return type(value) == "string" and value:match("^%x%x%x%x%x%x%x%x$") ~= nil
end

local function get_device_id(config)
    local id = normalize_device_id(config:get_string("input_stats/device_id"))
    if #id == 8 then return id end
    local user_dir = rime_api.get_user_data_dir()
    if not user_dir or user_dir == "" then return "00000000" end
    local file = io.open(user_dir:gsub("[/\\]+$", "") .. "/installation.yaml", "r")
    if not file then return "00000000" end
    for line in file:lines() do
        local value = line:match("^%s*installation_id%s*:%s*(.-)%s*$")
        if value then
            value = value:gsub("%s+#.*$", ""):gsub('^"(.*)"$', "%1")
                :gsub("^'(.*)'$", "%1")
            file:close()
            id = normalize_device_id(value)
            return #id == 8 and id or "00000000"
        end
    end
    file:close()
    return "00000000"
end

local function acquire_db(env)
    if env.stats_db then return env.stats_db end

    local entry = DB_POOL[env.stats_db_name]
    if not entry then
        local db = userdb.LevelDb(env.stats_db_name)
        if not db or not db:loaded() and not db:open() then
            env.stats_db_error = true
            return nil
        end
        entry = {db=db, refs=0}
        DB_POOL[env.stats_db_name] = entry
    elseif not entry.db or not entry.db:loaded() and not entry.db:open() then
        DB_POOL[env.stats_db_name] = nil
        env.stats_db_error = true
        return nil
    end

    entry.refs = entry.refs + 1
    env.stats_db = entry.db
    env.stats_db_error = nil
    return entry.db
end

local function get_db(env)
    return env.stats_db or acquire_db(env)
end

local function release_db(env)
    local db, db_name = env.stats_db, env.stats_db_name
    env.stats_db = nil

    local entry = db_name and DB_POOL[db_name]
    if not db or not entry or entry.db ~= db then return end

    entry.refs = math.max(0, entry.refs - 1)
    if entry.refs > 0 then return end

    DB_POOL[db_name] = nil

    -- DbAccessor 没有显式析构接口。所有局部访问器先置空，再执行一次
    -- 完整垃圾回收，确保其先于所引用的 LevelDb 释放。
    collectgarbage()

    if db:loaded() then db:close() end
    entry.db = nil
end

local function make_raw_key(key, device_id)
    if not key or key == "" or not is_device_id(device_id) then return nil end
    return key .. RECORD_SEPARATOR .. device_id
end

local function parse_raw_key(raw_key)
    if type(raw_key) ~= "string" then return nil, nil end
    local split = raw_key:find(RECORD_SEPARATOR, 1, true)
    if not split then return nil, nil end
    local key = raw_key:sub(1, split - 1)
    local device_id = raw_key:sub(split + #RECORD_SEPARATOR)
    if key == "" or not is_device_id(device_id) then return nil, nil end
    return key, device_id
end

local function to_integer(value)
    value = tonumber(value) or 0
    if value ~= value or value == math.huge or value == -math.huge then value = 0 end
    value = value < 0 and math.ceil(value) or math.floor(value)
    return math.max(0, math.min(STATS_C_MAX, value))
end

local function parse_tail(tail)
    if type(tail) ~= "string" then return 0 end
    local c, d, t = tail:match("^c=([^%s\t]+) d=([^%s\t]+) t=([^%s\t]+)$")
    c, d, t = tonumber(c), tonumber(d), tonumber(t)
    if not c or c < 0 or c ~= math.floor(c) or d ~= 0
        or not t or t < 0 or t ~= math.floor(t)
    then
        return 0
    end
    return to_integer(c)
end

local function db_get(db, key, device_id)
    local raw_key = make_raw_key(key, device_id)
    return raw_key and parse_tail(db:fetch(raw_key)) or 0
end

local function db_set(db, key, device_id, value)
    local raw_key = make_raw_key(key, device_id)
    return raw_key and db:update(raw_key,
        string.format("c=%d d=0 t=0", to_integer(value))) or false
end

local function db_add(db, key, device_id, amount)
    return db_set(db, key, device_id, db_get(db, key, device_id) + amount)
end

local function scan_prefix(db, prefix, device_id, handler)
    local accessor = db:query(prefix)
    if not accessor then return end

    do
        for raw_key, tail in accessor:iter() do
            if raw_key:sub(1, #prefix) ~= prefix then break end

            local key, record_device = parse_raw_key(raw_key)
            if key and (not device_id or record_device == device_id) then
                handler(key, record_device, parse_tail(tail), raw_key)
            end
        end
    end

    accessor = nil
end

local function monotonic_ms()
    if rime_api and rime_api.get_time_ms then
        return math.floor(rime_api.get_time_ms())
    end
    return os.time() * 1000
end

local function day_id(timestamp)
    local date = os.date("*t", timestamp or os.time())
    return string.format("%04d%02d%02d", date.year, date.month, date.day)
end

local function is_chinese(code)
    return (code >= 0x4E00 and code <= 0x9FFF)
        or (code >= 0x3400 and code <= 0x4DBF)
        or (code >= 0x20000 and code <= 0x2A6DF)
        or (code >= 0x2A700 and code <= 0x2B73F)
        or (code >= 0x2B740 and code <= 0x2B81F)
        or (code >= 0x2B820 and code <= 0x2CEAF)
        or (code >= 0x2CEB0 and code <= 0x2EBEF)
        or (code >= 0x30000 and code <= 0x3134F)
        or (code >= 0x31350 and code <= 0x323AF)
        or (code >= 0x2EBF0 and code <= 0x2EE5F)
        or (code >= 0xF900 and code <= 0xFAFF)
        or (code >= 0x2F800 and code <= 0x2FA1F)
        or (code >= 0x2E80 and code <= 0x2EFF)
        or (code >= 0x2F00 and code <= 0x2FDF)
end

local function chinese_length(text)
    local count = 0
    for _, code in utf8.codes(text) do
        if is_chinese(code) then count = count + 1 end
    end
    return count
end

local function new_stats()
    return {
        characters=0, commits=0, keystrokes=0,
        average_characters=0, average_milliseconds=0, average_sessions=0,
        peak_speed=nil,
        length_1=0, length_2=0, length_3=0, length_4=0, length_5_plus=0,
        lifetime_characters=0,
        code_len_without_space=0, auto_commits=0,
        backspaces=0,
        speed_keystrokes=0,
        average_keystrokes=0,
    }
end

local function pending_add(env, key, amount)
    local db = get_db(env)
    if env.stats_db_error or not db or not db:loaded() then return false end
    env.pending_stats[key] = (env.pending_stats[key] or 0) + amount
    return true
end

local function flush_pending(env)
    if not next(env.pending_stats) then return true end
    local db = get_db(env)

    if db and db:loaded() then
        for key, amount in pairs(env.pending_stats) do
            if not db_add(db, key, env.device_id, amount) then
                db = nil
                break
            end
        end
    end

    if not db then
        env.pending_stats = {}; env.pending_characters = 0
        env.stats_db_error = true
        return false
    end

    env.pending_stats = {}
    env.pending_characters = 0
    env.last_flush_ts = os.time()
    return true
end

local function try_flush(env)
    if next(env.pending_stats)
        and (env.pending_characters >= MAX_PENDING_CHARACTERS
            or os.time() - env.last_flush_ts >= BATCH_INTERVAL)
    then
        flush_pending(env)
    end
end

local function reset_sample(sample)
    sample.started = nil
    sample.last_activity = nil
    sample.last_commit = nil
    sample.characters = 0
    sample.keystrokes = 0
    sample.day = nil
end

local function start_sample(sample, day, timestamp_ms)
    sample.started = timestamp_ms
    sample.last_activity = timestamp_ms
    sample.last_commit = nil
    sample.characters = 0
    sample.keystrokes = 0
    sample.day = day
end

local function sample_values(sample, minimum_ms)
    if not sample.started or not sample.last_commit or sample.characters < 2 then
        return nil
    end
    local milliseconds = sample.last_commit - sample.started
    if milliseconds < minimum_ms then return nil end
    return sample.day, sample.characters, milliseconds, sample.keystrokes
end

local function finish_average(env)
    local day, characters, milliseconds, keystrokes = sample_values(
        env.average_sample, env.minimum_average_session_ms
    )
    reset_sample(env.average_sample)
    if not day then return false end
    local prefix = DAY_PREFIX .. day .. "/speed_average/"
    pending_add(env, prefix .. "characters", characters)
    pending_add(env, prefix .. "milliseconds", milliseconds)
    pending_add(env, prefix .. "keystrokes", keystrokes)
    pending_add(env, prefix .. "sessions", 1)
    return true
end

local function peak_speed(characters, milliseconds)
    return math.max(0, math.min(2000,
        math.floor(characters * 60000 / milliseconds + 0.5)))
end

local function finish_peak(env)
    local window_ms = env.peak_window_ms or PEAK_WINDOW_MS
    local day, characters, milliseconds = sample_values(
        env.peak_sample, window_ms
    )
    reset_sample(env.peak_sample)
    if not day then return false end
    -- 桶名后缀由窗口长度推导（env.peak_key_prefix），不写死，避免"键名和口径对不上"
    local prefix = env.peak_key_prefix or peak_key_prefix(window_ms)
    pending_add(env, string.format("%s%s/%s/%04d",
        DAY_PREFIX, day, prefix, peak_speed(characters, milliseconds)), 1)
    return true
end

local function ensure_sample(sample, day, timestamp_ms, gap_ms, finish)
    if sample.started then
        local gap = timestamp_ms - (sample.last_activity or sample.started)
        if gap >= 0 and gap <= gap_ms and sample.day == day then return end
        finish()
    end
    start_sample(sample, day, timestamp_ms)
end

local function finish_stale(env, timestamp_ms)
    local peak = env.peak_sample
    if peak.started and timestamp_ms - (peak.last_activity or peak.started)
        > env.continuous_gap_ms
    then
        finish_peak(env)
    end
    local average = env.average_sample
    if average.started and timestamp_ms - (average.last_activity or average.started)
        > env.average_gap_ms
    then
        finish_average(env)
    end
end

local function observe_input_activity(env, input)
    local timestamp_ms = monotonic_ms()
    -- "=" 开头的输入是指令（=tj/=qb/…），不是打字节奏，不参与速度采样
    if not input or input == "" or input:sub(1, 1) == "=" then
        finish_stale(env, timestamp_ms)
        env.last_observed_input = input or ""
        return
    end
    if input == env.last_observed_input then return end
    env.last_observed_input = input
    local day = day_id()
    ensure_sample(env.average_sample, day, timestamp_ms, env.average_gap_ms,
        function() finish_average(env) end)
    -- 峰速窗口：与均速共用同一个「连续输入」间隙（env.peak_gap_ms == average_gap_ms），
    -- 累计满 env.peak_window_ms 才结算；不足的窗口作废——长停顿不稀释速度。
    ensure_sample(env.peak_sample, day, timestamp_ms,
        env.peak_gap_ms or PEAK_GAP_MS,
        function() finish_peak(env) end)
    env.average_sample.last_activity = timestamp_ms
    env.peak_sample.last_activity = timestamp_ms
end

local function commit_to_speed(env, day, timestamp_ms, characters, keystrokes)
    -- 会话内键数累计：击键速度分子与分母同一批会话（口径一致）
    env.average_sample.keystrokes = (env.average_sample.keystrokes or 0)
        + (keystrokes or 0)
    ensure_sample(env.average_sample, day, timestamp_ms, env.average_gap_ms,
        function() finish_average(env) end)
    ensure_sample(env.peak_sample, day, timestamp_ms,
        env.peak_gap_ms or PEAK_GAP_MS,
        function() finish_peak(env) end)
    local average, peak = env.average_sample, env.peak_sample
    average.last_activity = timestamp_ms
    average.last_commit = timestamp_ms
    average.characters = average.characters + characters
    peak.last_activity = timestamp_ms
    peak.last_commit = timestamp_ms
    peak.characters = peak.characters + characters
    local window_ms = env.peak_window_ms or PEAK_WINDOW_MS
    if peak.last_commit - peak.started >= window_ms then finish_peak(env) end
    env.last_observed_input = ""
end

local function is_valid_speed_commit(env, characters, code_length)
    if code_length <= 0 or characters > env.max_speed_commit_length then
        return false
    end

    return characters <= math.max(4, code_length * 2)
end

local function record_stats(env, characters, code_length, speed_code_length,
        code_len_without_space, is_auto_commit, backspaces)
    local timestamp_ms = monotonic_ms()
    local day = day_id()
    local prefix = DAY_PREFIX .. day .. "/"
    if not pending_add(env, prefix .. "text/characters", characters) then return end
    pending_add(env, prefix .. "text/commits", 1)
    pending_add(env, prefix .. "text/keystrokes", code_length)
    if backspaces and backspaces > 0 then
        pending_add(env, prefix .. "text/backspaces", backspaces)
    end
    if code_len_without_space and code_len_without_space > 0 then
        pending_add(env, prefix .. "text/code_len_without_space", code_len_without_space)
    end
    if is_auto_commit then pending_add(env, prefix .. "text/auto_commits", 1) end
    env.pending_characters = env.pending_characters + characters
    local field = characters == 1 and "commit_length/1"
        or characters == 2 and "commit_length/2"
        or characters == 3 and "commit_length/3"
        or characters == 4 and "commit_length/4"
        or "commit_length/5_plus"
    pending_add(env, prefix .. field, 1)
    if is_valid_speed_commit(env, characters, speed_code_length) then
        commit_to_speed(env, day, timestamp_ms, characters, speed_code_length)
    else
        finish_peak(env)
        finish_average(env)
        env.last_observed_input = ""
    end
end

local function in_day_range(day, start_day, end_day)
    return (not start_day or day >= start_day) and (not end_day or day <= end_day)
end

-- [0913] 峰速 = 当日所有窗口样本里的**最高**字/分。
--   抗噪不靠对结果做手脚，靠窗口本身：必须连续输入满 PEAK_WINDOW_MS 才结算一个样本，
--   短促爆发凑不满窗口就已经作废了。
--
--   沿革：上游 4.2 曾在这里写死"取次高"（样本 ≥2 时 rank 从 2 起算）且无注释，
--   害得峰速常年偏低、还会跟均速打架。中途试过"要求复现 = 取第 N 高（N=3）"，
--   用户实测后判定不必要，已回退到取最高。**不要再引入任何"跳过最高值"的逻辑。**
local function calculate_peak(peaks)
    local best
    for speed, count in pairs(peaks) do
        if count > 0 and (best == nil or speed > best) then
            best = speed
        end
    end
    return best
end

local function aggregate_statistics(env, start_day, end_day, device_id,
        speed_start_day, speed_end_day)
    speed_start_day = speed_start_day or start_day
    speed_end_day = speed_end_day or end_day
    local db = get_db(env)
    if not db or not db:loaded() then return nil end
    local stats, peaks = new_stats(), {}

    scan_prefix(db, STATISTICS_PREFIX, device_id,
        function(key, record_device, value)
        local day, field = key:match("^statistics/day/(%d%d%d%d%d%d%d%d)/(.+)$")
        if not day then return end
        if field == "text/characters" then
            stats.lifetime_characters = stats.lifetime_characters + value
        end

        if field == "text/keystrokes"
            and in_day_range(day, speed_start_day, speed_end_day)
        then
            stats.speed_keystrokes = stats.speed_keystrokes + value
        end

        local target = DAY_FIELDS[field]
        if target then
            if in_day_range(day, start_day, end_day) then
                stats[target] = stats[target] + value
            end
            return
        end

        if not in_day_range(day, speed_start_day, speed_end_day) then return end

        local average_field = field:match("^speed_average/([^/]+)$")
        if average_field == "characters" then
            stats.average_characters = stats.average_characters + value
        elseif average_field == "milliseconds" then
            stats.average_milliseconds = stats.average_milliseconds + value
        elseif average_field == "keystrokes" then
            stats.average_keystrokes = stats.average_keystrokes + value
        elseif average_field == "sessions" then
            stats.average_sessions = stats.average_sessions + value
        else
            -- 只认「当前窗口长度」对应的桶名，别的后缀（历史遗留/改过窗口的）一律不算，
            -- 否则不同窗口长度测出来的速度会被混进同一个峰速里比大小。
            local prefix = env.peak_key_prefix or peak_key_prefix(
                env.peak_window_ms or PEAK_WINDOW_MS)
            local speed = field:match("^" .. prefix .. "/(%d%d%d%d)$")
            if speed then
                speed = tonumber(speed)
                peaks[speed] = (peaks[speed] or 0) + value
            end
        end
    end)
    local day, characters, milliseconds, keystrokes = sample_values(
        env.average_sample, env.minimum_average_session_ms
    )
    if day and in_day_range(day, speed_start_day, speed_end_day)
        and (not device_id or device_id == env.device_id)
    then
        stats.average_characters = stats.average_characters + characters
        stats.average_milliseconds = stats.average_milliseconds + milliseconds
        stats.average_keystrokes = stats.average_keystrokes + (keystrokes or 0)
        stats.average_sessions = stats.average_sessions + 1
    end
    day, characters, milliseconds = sample_values(env.peak_sample,
        env.peak_window_ms or PEAK_WINDOW_MS)
    if day and in_day_range(day, speed_start_day, speed_end_day)
        and (not device_id or device_id == env.device_id)
    then
        local speed = peak_speed(characters, milliseconds)
        peaks[speed] = (peaks[speed] or 0) + 1
    end
    if stats.average_milliseconds < env.minimum_average_total_ms then
        stats.average_characters = 0
        stats.average_milliseconds = 0
        stats.average_keystrokes = 0
        stats.average_sessions = 0
        stats.speed_keystrokes = 0
    end
    stats.peak_speed = calculate_peak(peaks)
    return stats.commits > 0 and stats or nil
end

local function migrate_database(env)
    local db = get_db(env)
    if not db or not db:loaded() then return end
    local additions, old_keys = {}, {}
    scan_prefix(db, "d_", nil, function(key, device_id, value, raw_key)
        old_keys[#old_keys + 1] = raw_key
        local day, suffix = key:match("^d_(%d%d%d%d%d%d%d%d)(_.+)$")
        local target = day and LEGACY_FIELDS[suffix]
        if target and value > 0 and db_get(db, MIGRATION_KEY, device_id) == 0 then
            local device = additions[device_id] or {}
            additions[device_id] = device
            local new_key = DAY_PREFIX .. day .. "/" .. target
            device[new_key] = (device[new_key] or 0) + value
        end
    end)
    scan_prefix(db, "total_", nil, function(_, _, _, raw_key)
        old_keys[#old_keys + 1] = raw_key
    end)
    for device_id, values in pairs(additions) do
        local success = true
        for key, value in pairs(values) do
            if value > db_get(db, key, device_id)
                and not db_set(db, key, device_id, value)
            then
                success = false
                break
            end
        end
        if success then db_set(db, MIGRATION_KEY, device_id, 1) end
    end
    for _, raw_key in ipairs(old_keys) do db:erase(raw_key) end
    local obsolete = {}
    local current_peak_prefix = env.peak_key_prefix or peak_key_prefix(
        env.peak_window_ms or PEAK_WINDOW_MS)
    scan_prefix(db, STATISTICS_PREFIX, nil, function(key, _, _, raw_key)
        if key:match("^statistics/day/%d%d%d%d%d%d%d%d/speed/[^/]+$")
            or key:match("^statistics/day/%d%d%d%d%d%d%d%d/average_speed/[^/]+$")
            or key:match("^statistics/day/%d%d%d%d%d%d%d%d/peak_speed/[^/]+$")
            or key:match("^statistics/day/%d%d%d%d%d%d%d%d/speed_peak/")
            or key:match("^statistics/day/%d%d%d%d%d%d%d%d/speed_peak_window/")
            or key:match("^statistics/hour/") then
            obsolete[#obsolete + 1] = raw_key
        else
            -- [0913] 峰速桶用的是「窗口长度」当后缀：只保留与当前窗口一致的那一种。
            -- 这样改过 PEAK_WINDOW_MS 之后，旧后缀的样本会自动出局，
            -- 不会出现"10 秒窗口测的"和"15 秒窗口测的"被当成同一个峰速来比。
            local bucket = key:match(
                "^statistics/day/%d%d%d%d%d%d%d%d/(speed_peak_window_[^/]+)/")
            if bucket and bucket ~= current_peak_prefix then
                obsolete[#obsolete + 1] = raw_key
            end
        end
    end)
    for _, raw_key in ipairs(obsolete) do db:erase(raw_key) end
end

local function platform_info(name, version)
    local names = {
        Weasel="小狼毫", trime="同文输入法", hamster3="元书输入法",
        hamster="仓输入法", lyraime="灵韵输入法", xime="曦码输入法",
        ["Cobra​"]="元书输入法(PC)", default="超越输入法",
    }
    version = tostring(version or "")
    return names[name] or name or "",
        version:match("^([vV]?%d+%.%d+%.%d+)") or version
end

local function ensure_titles(env)
    if env.titles then return env.titles end
    local titles = {}
    local configured = env.engine.schema.config:get_list("input_stats/titles")
    if configured then
        for i = 0, configured.size - 1 do
            local item = configured:get_value_at(i)
            local value = item and item.value
            if value then
                local threshold, name = value:match("^(%d+):(.+)$")
                if threshold and name then
                    titles[#titles + 1] = {tonumber(threshold), name}
                end
            end
        end
    end
    if #titles == 0 then
        local theme = TITLE_THEMES[env.title_theme] or TITLE_THEMES[DEFAULT_TITLE_THEME]
        env.titles = theme
    else
        table.sort(titles, function(a, b) return a[1] > b[1] end)
        env.titles = titles
    end
    return env.titles
end

-- [0820] 金山打字通速度等级（峰速查表）
-- [0913] 面板改版后已弃用：评语改由 REALMS 表的「今日境界」给出（保留代码以防回退）
-- 标准对照（网上金山打字通十级划分）：10/40/70/100/120/140/160/180/200/300 字/分
local SPEED_LEVELS = {
    {300, "传说级·人键合一"},
    {200, "神之领域，豹变传奇"},
    {180, "行云流水的打字高手"},
    {160, "鹰击长空，键指如飞"},
    {140, "跟上节拍的节奏大师"},
    {120, "兔跃轻舞，速度渐起"},
    {100, "打字如龟速爬行中"},
    {70, "一指禅，敲出千古韵"},
    {40, "处于边打字边打盹状态Zzz"},
    {10, "再慢也是一种态度"},
}
local SPEED_CN = {"一", "二", "三", "四", "五", "六", "七", "八", "九", "十"}
-- 返回：等级名（"四级"）、评语、图标（1-2级🐌 / 3-4级🐢 / 5-6级🐇 / 7-8级🦅 / 9-10级🐆）
local function speed_level(peak)
    for i, lv in ipairs(SPEED_LEVELS) do
        if peak and peak >= lv[1] then
            local n = 11 - i
            local icon = "🐆"
            if n <= 2 then icon = "🐌"
            elseif n <= 4 then icon = "🐢"
            elseif n <= 6 then icon = "🐇"
            elseif n <= 8 then icon = "🦅" end
            return SPEED_CN[n] .. "级", lv[2], icon
        end
    end
    return "一级", SPEED_LEVELS[10][2], "🐌"
end

local function user_title(env, characters)
    -- 返回 (段位名, 从低到高的序号, 总段位数)，如 渐入佳境 → (…, 2, 7)
    local titles = ensure_titles(env)
    for i, item in ipairs(titles) do
        if characters >= item[1] then
            return item[2], #titles - i + 1, #titles
        end
    end
    return "初学乍练", 1, #titles
end

local function draw_bar(percent, env)
    local skin = skinList[(env and env.skin_word) or DEFAULT_SKIN]
        or skinList[DEFAULT_SKIN]
    if skin.half then
        -- [0827] 个位数 1-9 显示半格：整格数 = 十位数；有零头（非整格）就补半格
        local full = math.floor(percent / 10)
        local rem = percent - full * 10
        if rem >= 1 and full < 10 then
            return string.rep(skin.field, full) .. skin.half
                .. string.rep(skin.empty, 9 - full)
        end
        return string.rep(skin.field, full) .. string.rep(skin.empty, 10 - full)
    end
    -- 无半格字符的皮肤：10 格整数（每格 10%，向下取整）
    local filled = math.floor(percent / 10)
    return string.rep(skin.field, filled) .. string.rep(skin.empty, 10 - filled)
end

-- [0913] 比例条（新版面板专用）：固定 6 格，字符仍走皮肤（=wkp 可切）
local function draw_bar6(percent, env)
    local skin = skinList[(env and env.skin_word) or DEFAULT_SKIN]
        or skinList[DEFAULT_SKIN]
    local filled = math.floor(percent * 6 / 100 + 0.5)
    if filled < 0 then filled = 0 elseif filled > 6 then filled = 6 end
    return string.rep(skin.field, filled) .. string.rep(skin.empty, 6 - filled)
end

-- [0913] 打字境界：只看「峰速」，峰速每多 15 字/分 进一境（原本是 10，用户改为 15）。
--   15~29 → 识符境   30~44 → 运指境   45~59 → 缀文境   60~74 → 顺章境
--   75~89 → 凝心境   90~104 → 御字境  105~119 → 通章境  120~134 → 合契境
--   135~149 → 化文境  ≥150  → 道成境
--   峰速不足 15（含峰速未出数 "--"）→ 未入道
--   例：峰速 47 → 缀文境；峰速 140 → 化文境
-- 评价文字由用户指定，一字不改（第 7 境原稿「整篇文化」已按用户更正为「整篇文稿」）
-- ⚠️ 只改这里的阈值即可调整档距；10 个境界名与顺序保持不变。
local REALMS = {
    { 15,  "识符境", "初识字符，辨认字根" },
    { 30,  "运指境", "熟悉布局，缓慢敲出文字" },
    { 45,  "缀文境", "连贯打出，单字不卡顿" },
    { 60,  "顺章境", "整句流畅，指法初养成" },
    { 75,  "凝心境", "眼到手到，心神专注" },
    { 90,  "御字境", "节奏稳定，持续输入" },
    { 105, "通章境", "整篇文稿，一气呵成" },
    { 120, "合契境", "心神与文字相融" },
    { 135, "化文境", "念头一动文字即出" },
    { 150, "道成境", "字道圆满，随心而输，快慢由心" },
}
-- 未入道：峰速不足最低一境时的占位；面板里带【】显示，和真实境界区分开
local NO_REALM_NAME = "【未入道】"
local NO_REALM_COMMENT = "以文字为道｜击字炼心方能入道"

-- 返回：境界名 + 该境界的评语（峰速为 nil / 不足最低一境 → 未入道）
local function realm_of(peak)
    if not peak or peak < REALMS[1][1] then
        return NO_REALM_NAME, NO_REALM_COMMENT
    end
    local top = REALMS[#REALMS]
    if peak >= top[1] then return top[2], top[3] end
    for i = #REALMS - 1, 1, -1 do
        if peak >= REALMS[i][1] then return REALMS[i][2], REALMS[i][3] end
    end
    return NO_REALM_NAME, NO_REALM_COMMENT
end

-- 数值右对齐到 width 个半角宽（"　"=2、" "=1）。
-- 面板前四行是「标签 + 定宽数值 ｜ 标签 + 定宽数值」的 2×2 格子，
-- 数值必须右对齐，两行的 ｜ 才会上下对齐：
--   均速　　24　｜　峰速　　47      ← "24" 补成 6 宽 → "　　24"
--   上屏　2145　｜　字数　3033      ← "2145" 补成 6 宽 → "　2145"
local function pad_val(s, width)
    local w = 0
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        if b < 128 then w = w + 1; i = i + 1
        else
            local l = 1
            if b >= 240 then l = 4 elseif b >= 224 then l = 3 elseif b >= 192 then l = 2 end
            w = w + 2; i = i + l
        end
    end
    local out = s
    while w + 2 <= width do out = "　" .. out; w = w + 2 end
    if w < width then out = " " .. out end
    return out
end

local function format_summary(title, subtitle, data, env)
    if not data or data.commits == 0 then return "※ " .. title .. "暂无数据" end
    -- [0913] 旧版这里的「◉ 键数：累计 N 键」行已随面板改版去掉
    --（新版 9 行版式固定，不显示累计键数；数据仍在库里，只是不上面板）
    local average_code = data.characters > 0 and data.keystrokes / data.characters or 0
    -- 击键速度 = 会话键数 ÷ 会话时长（分子分母同一批会话，口径一致）
    -- 旧数据兼容：升级前的库无 speed_average/keystrokes 字段 → 回退旧口径
    local session_keys = data.average_keystrokes or 0
    if session_keys <= 0 then
        session_keys = data.speed_keystrokes or 0
    end
    local kps = data.average_milliseconds > 0
        and session_keys * 1000 / data.average_milliseconds or nil
    local kps_str = kps and string.format("%.2f", kps) or "--"
    -- [0812] 空格上屏次数 = 上屏总次数 − 自动顶屏次数（与四码上屏互补，合计≈100%）
    local space_commits = data.commits - (data.auto_commits or 0)
    if space_commits < 0 then space_commits = 0 end
    local space_ratio = data.commits > 0 and 100 * space_commits / data.commits or 0
    local auto_commits = data.auto_commits or 0
    local auto_ratio = data.commits > 0 and 100 * auto_commits / data.commits or 0
    local average_speed = data.average_milliseconds > 0
        and math.floor(data.average_characters * 60000
            / data.average_milliseconds + 0.5) or nil
    -- [0913] 峰速为 0 说明那个窗口里一个字都没打（等同未出数）→ 统一显示 "--"，
    -- 也让第 2 行的境界落到「未入道」，不会出现「峰速 0 却是某境」的怪组合。
    -- [0913] 峰速只做「有没有数据」这一道校验，不再做「低于均速就隐藏」的相对判断。
    --   峰速 = 最快的那一段连续输入，均速 = 全部会话的加权平均；段短但快（打完一句就停手）
    --   时 peak < average 是**完全正常**的。旧守卫把这种正常情况当成异常藏掉，
    --   叠加上「取次高」就出现了"桶里明明有 136，面板却显示 --"。
    local peak_speed = data.peak_speed
    if not peak_speed or peak_speed <= 0 then peak_speed = nil end
    -- [0913] 单字/词组占比改用「字数」口径（单字次数 × 1 字）
    local chars_n = data.characters or 0
    local single_n = data.length_1 or 0
    local single_pct = chars_n > 0 and (100 * single_n / chars_n) or 0
    local word_pct = 100 - single_pct

    -- [0913] 境界 + 评语：只看峰速（峰速未出数 / 不足最低一境 → 【未入道】）
    local realm_name, realm_comment = realm_of(peak_speed)
    local zwsp = "\226\128\139"

    -- [0914] 用户指定版式（第 3 版）：时段前缀 <xx> 加在 **境界 / 均速 / 峰速 / 上屏 / 字数 / 比例**
    --   这 6 处；评语 / 心法 / 功法 / 标题 / 方案名 不带前缀。
    --   第 2 行由「🌾<境界> · 修炼生涯 N 字」改为「<xx>境界 → <境界名>」，
    --   修炼生涯不再单列——=qb 面板的「全部字数」就是生涯累计，信息不丢。
    --   例外：subtitle 非空的 =jq / =wx 仍把设备号 / 日期接在境界行尾，否则查了哪天根本看不出来。
    local xx = title
    local day_tail = ""
    if subtitle and subtitle ~= "" then day_tail = " · " .. subtitle end

    -- [0914] 面板版式：6 组、共 9 行，组间空一行（空行只放零宽空格，防止被候选窗折叠）。
    --   组1 标题 + 境界 / 组2 评语 / 组3 均速峰速 + 上屏字数 /
    --   组4 心法 + 功法 / 组5 比例 / 组6 方案名
    --   ⚠️ 第 3 版起：评语组由「均速/上屏之后」提到「境界之后」（按用户交付稿的行序）。
    local groups = {
        {
            "📖 键盘之道·以击键炼字为修行",
            xx .. "境界 → " .. realm_name .. day_tail,
        },
        {
            -- 用户指定：评语行的分隔符是「｜」（不是 心法/功法 那样的全角空格），
            -- 且不带 📜 图标；未入道的评语本身也含一个 ｜。
            "评语｜" .. realm_comment,
        },
        {
            -- 左列值补到 6 个半角宽，"　｜　" 分隔，两行的 ｜ 才会对齐
            xx .. "均速" .. pad_val(average_speed and tostring(average_speed) or "--", 6)
                .. "　｜　" .. xx .. "峰速"
                .. pad_val(peak_speed and tostring(peak_speed) or "--", 6),
            xx .. "上屏" .. pad_val(tostring(math.floor(data.commits)), 6)
                .. "　｜　" .. xx .. "字数"
                .. pad_val(tostring(math.floor(data.characters)), 6),
        },
        {
            "心法　码长 " .. string.format("%.2f", average_code)
                .. " · 击键 " .. kps_str .. "/s",
            -- [0913] 「空格 / 顶屏」改口径名「非顶 / 顶功」：
            --   非顶 = 按空格或数字选字上屏（原「空格」），顶功 = 被下一个编码键顶上去
            string.format("功法　非顶 %d%% · 顶功 %d%%",
                math.floor(space_ratio + 0.5), math.floor(auto_ratio + 0.5)),
        },
        {
            string.format("%s比例　单 %d %% %s %d %% 词",
                xx, math.floor(single_pct + 0.5), draw_bar6(single_pct, env),
                math.floor(word_pct + 0.5)),
        },
        {
            -- [0913] 用户要求去掉设备/前端，末行只留方案名
            "—  " .. env.schema_name .. " —",
        },
    }
    local out = {}
    for gi = 1, #groups do
        if gi > 1 then out[#out + 1] = zwsp end     -- 组间空行（只有零宽空格，不会显示字符）
        for li = 1, #groups[gi] do
            out[#out + 1] = groups[gi][li] .. zwsp
        end
    end
    -- 行尾补零宽空格（沿用旧面板习惯，防止候选窗把行长当换行处理）。
    -- 面板首字符是 "📖"，on_commit 的「机器文本」识别串必须含 📖。
    return table.concat(out, "\n")
end

local function yield_msg(seg, text, icon)
    yield(Candidate("stat", seg.start, seg._end, text, icon or "🕰️"))
end

local function prepare_report(env)
    finish_stale(env, monotonic_ms())
    flush_pending(env)
end

-- 指令一律以 "=" 触发（键道6 的 "o" 已被 recognizer/patterns/xmjd6gbk 占用为五笔画查询，
-- 4.2 那套 o + 去斜杠 的别名机制在本方案会把 ortj 抢成 O 模式查询，已整体删除）
local function standard_report(input, env)
    local today = day_id()
    -- 「卅日」窗口：固定 30 天，**与速度统计窗口无关**。
    -- 原先这里和下面共用同一个 recent，是个耦合错误：一旦把 speed_history_days 调成 0（不限），
    -- =yy 的 start_day 也会变成 nil，卅日面板会跟着塌成"全部"。
    local month_start = day_id(os.time() - 29 * 86400)
    -- 速度统计窗口：只作用于「均速 / 峰速 / 击键」的聚合范围。
    -- speed_history_days <= 0 → speed_start = nil → aggregate_statistics 不限下限，从最早一天算起。
    local speed_start = nil
    if (env.speed_history_days or 0) > 0 then
        speed_start = day_id(os.time() - (env.speed_history_days - 1) * 86400)
    end

    if input == env.triggers.local_total then
        return "本设备", "设备 " .. env.device_id, nil, nil, env.device_id,
            speed_start, today
    elseif input == env.triggers.today then
        return "今日", "", today, today, nil, today, today
    elseif input == env.triggers.week then
        local start_day = day_id(os.time() - 6 * 86400)
        return "七日", "", start_day, today, nil, start_day, today
    elseif input == env.triggers.month then
        return "卅日", "", month_start, today, nil, month_start, today
    elseif input == env.triggers.year then
        local start_day = day_id(os.time() - 364 * 86400)
        return "本年", "", start_day, today, nil, start_day, today
    elseif input == env.triggers.total then
        return "全部", "", nil, nil, nil, speed_start, today
    end
end

local function history_report(input, env)
    local trigger = env.triggers.history
    if input:sub(1, #trigger) ~= trigger then return nil end
    local query = input:sub(#trigger + 1)
    if query == "" then
        return false, "※ 请输入日期或区间（例 " .. trigger .. "2026、" ..
            trigger .. "202601、" .. trigger .. "20260101t20260201）", "⌨️"
    end
    local sy, sm, sd, ey, em, ed =
        query:match("^(%d%d%d%d)(%d%d)(%d%d)t(%d%d%d%d)(%d%d)(%d%d)$")
    if sy then
        prepare_report(env)
        return aggregate_statistics(env, sy .. sm .. sd, ey .. em .. ed),
            "区间", string.format("%s.%s.%s - %s.%s.%s", sy, sm, sd, ey, em, ed),
            "※ 该区间内没有留下打字记录哦"
    end
    local y, m, d = query:match("^(%d%d%d%d)(%d%d)(%d%d)$")
    if y then
        prepare_report(env)
        local day = y .. m .. d
        return aggregate_statistics(env, day, day), "当日",
            string.format("%s.%s.%s", y, m, d), "※ 这一天没有留下打字记录哦"
    end
    y, m = query:match("^(%d%d%d%d)(%d%d)$")
    if y then
        prepare_report(env)
        return aggregate_statistics(env, y .. m .. "01", y .. m .. "31"),
            "当月", string.format("%s年%s月", y, m), "※ 该月没有留下打字记录哦"
    end
    y = query:match("^(%d%d%d%d)$")
    if y then
        prepare_report(env)
        return aggregate_statistics(env, y .. "0101", y .. "1231"),
            "当年", string.format("%s年", y), "※ 该年没有留下打字记录哦"
    end
    return false, query:find("t", 1, true) and "※ 正在输入区间查询..."
        or "※ 正在查询中... 请继续输入完整的年/月/日", "⏳"
end

local function on_commit(context, env)
    -- [增强] 先取走真实击键数（含空格/数字选字/退格等），无论是否统计都清零防残留
    -- take() 返回 (总键数, 退格数)；退格数用于平均键准统计
    local real_keystrokes, backspaces, last_type = nil, 0, nil
    if ok_key_counter then
        local a, b, c = key_counter.take()
        real_keystrokes = a or 0
        backspaces = b or 0
        last_type = c
    end
    local text = context:get_commit_text()
    -- 当前编码串：上屏瞬间还带着 "=" 前缀 = 这是工具类提交（=123→壹佰贰拾叁、
    -- =1+1→3、=uuid…），不是在打字，一律不记账。
    local raw_input = context.input or ""
    if not text or text == "" or text:sub(1, 1) == "="
        or raw_input:sub(1, 1) == "="
        or text:find("^[※◉🏆📊⚡📈📖]") then
        -- 指令/面板文本上屏：清空待取击键防残留（take 已取走，这里双保险）
        if ok_key_counter and key_counter.reset then key_counter.reset() end
        return
    end
    local characters = chinese_length(text)
    if characters == 0 then return end
    local code = raw_input
    if code == "" then code = env.last_observed_input or "" end
    local code_length = #code
    -- 不含空格的编码长度（空格上屏计算的基础）
    local code_len_without_space = code_length
    -- ══════════════════════════════════════
    -- 顶屏判定
    --
    -- TOPUP_MODE（键道6 / 变长顶功）：不看固定码长，只看「本次上屏的末键类型」。
    --   topup/topup_with: "avuio;"  min_length: 4  min_length_danzi: 2
    --   → 2 码简码、4 码单字、5~6 码全码都可能被下一个编码键顶上去，
    --     根本不存在"第 N 码直接顶屏"这回事，所以固定码长模型必须废掉。
    --
    --   末键 = "1"（编码键）→ 被下一个字的编码键顶上（顶功上屏，全程没按空格）。
    --       最后那 1 键是下一个字的第一个码，必须还回去，本次码长要减 1。
    --   末键 = "4"（选字/提交键）→ 空格 / 数字 / 回车 / [] 主动上屏（非顶功）。
    --
    -- 非 TOPUP_MODE：保留「码长击键计数器 4.2」的「真实击键数 vs 固定顶屏码数」模型。
    -- ══════════════════════════════════════
    local is_auto_commit
    if real_keystrokes and real_keystrokes > 0 then
        local raw = real_keystrokes          -- 本次上屏的原始真实击键数
        if TOPUP_MODE then
            if last_type == "1" and raw >= 2 then
                is_auto_commit = true                       -- 顶功上屏
                if ok_key_counter and key_counter.restore_last then
                    key_counter.restore_last()              -- 最后 1 键还给下一个字
                end
                code_length = raw - 1
                code_len_without_space = raw - 1
            else
                is_auto_commit = false                      -- 空格 / 数字选字上屏
                code_length = raw                           -- 含那个上屏键
                code_len_without_space = raw > 1 and (raw - 1) or raw
            end
        else
            -- 4.2 原模型：diff = real - 顶屏码数（默认4）
            --   0  且末键是编码键 → 纯顶屏
            --   1  且末键是编码键 → 次选顶屏（含下一字首码）/顶屏时序
            --   2  且末键是编码键 → 桌面 repeat/时序宽容（多余键丢弃）
            --   末键是选字键(4)   → 空格/数字选字上屏（非顶屏）
            local ac = env.auto_commit_code_len or 0
            if ac > 0 then
                local diff = raw - ac
                if diff == 0 and last_type == "1" then
                    is_auto_commit = true
                elseif diff == 1 and last_type == "1" then
                    is_auto_commit = true
                    if ok_key_counter and key_counter.restore_last then
                        key_counter.restore_last()
                    end
                    raw = ac
                elseif diff == 2 and last_type == "1" then
                    is_auto_commit = true
                    if ok_key_counter and key_counter.reset then key_counter.reset() end
                    raw = ac
                else
                    is_auto_commit = false
                end
            end
            code_length = raw
        end
    else
        -- 无计数器回退：码长命中顶屏码数即视为顶屏
        is_auto_commit = (env.auto_commit_code_len or 0) > 0
            and code_len_without_space == env.auto_commit_code_len
        -- 无击键器时回退码长统计：非顶屏上屏补 1 键（空格键）；顶屏不加（少计一键）
        if not is_auto_commit then code_length = code_length + 1 end
    end
    record_stats(env, characters,
        code_length > 0 and code_length or characters * 2, code_length,
        code_len_without_space, is_auto_commit, backspaces)
    try_flush(env)
end

local function bounded_int(config, key, default, minimum, maximum)
    return math.max(minimum, math.min(maximum, config:get_int(key) or default))
end

-- [0813] 兜底初始化：部分桌面 Rime（小狼毫等）的 librime-lua 可能不调用 translator 的
-- init，导致 auto_commit_code_len/triggers 等缺失：顶屏判定恒为"空格上屏"，
-- =tj 等指令也不识别（指令键残留进码长）。
-- ensure_env 幂等：translator 首次运行时补齐全部关键配置；init 也调用它。
-- [0813] 配置读取：空串视为未配置（部分 Rime 发行版 get_string 返回 "" 而非 nil）
local function cfg_str(config, key, default)
    local v = config:get_string(key)
    if v == nil or v == "" then return default end
    return v
end

local function ensure_env(env)
    -- 逐字段补全（幂等）：init 已设的字段不动，缺失的补齐——比整体跳过更健壮
    if not env.engine or not env.engine.schema then return end
    local config = env.engine.schema.config
    if env.schema_name == nil then
        -- [0913] 面板末行要的是「方案显示名」（custom 里的 schema/name，如 🌟🐈），
        -- 不是 schema_id（xmjd6）。取不到再退回 schema_id，最后兜底。
        env.schema_name = cfg_str(config, "schema/name", nil)
            or env.engine.schema.schema_name
            or "星猫键道6"
    end
    if env.stats_db_name == nil then
        env.stats_db_name = config:get_string("input_stats/db_name") or "stats"
        if env.stats_db_name == "" then env.stats_db_name = "stats" end
    end
    if env.device_id == nil then env.device_id = get_device_id(config) end
    if env.continuous_gap_ms == nil then
        env.continuous_gap_ms = bounded_int(config, "input_stats/continuous_gap_ms",
            CONTINUOUS_GAP_MS, 200, 5000)
    end
    if env.average_gap_ms == nil then
        env.average_gap_ms = bounded_int(config, "input_stats/average_gap_ms",
            AVERAGE_GAP_MS, env.continuous_gap_ms, 30000)
    end
    if env.minimum_average_session_ms == nil then
        env.minimum_average_session_ms = bounded_int(config,
            "input_stats/minimum_average_session_ms",
            MINIMUM_AVERAGE_SESSION_MS, 500, 10000)
    end
    if env.minimum_average_total_ms == nil then
        env.minimum_average_total_ms = bounded_int(config,
            "input_stats/minimum_average_total_ms",
            MINIMUM_AVERAGE_TOTAL_MS, 3000, 120000)
    end
    if env.max_speed_commit_length == nil then
        env.max_speed_commit_length = bounded_int(config,
            "input_stats/max_speed_commit_length",
            MAX_SPEED_COMMIT_LENGTH, 1, 10)
    end
    -- [0718] 顶屏码数：脚本顶部 AUTO_COMMIT_CODE_LEN（默认4），schema 可覆盖
    if env.auto_commit_code_len == nil then
        env.auto_commit_code_len = config:get_int("input_stats/code_len_of_auto_commit")
            or AUTO_COMMIT_CODE_LEN
    end
    if env.speed_history_days == nil then
        -- 0 = 不限（用全部历史）；它只决定「统计多少天」，不删除任何记录。
        env.speed_history_days = bounded_int(config,
            "input_stats/speed_history_days", SPEED_HISTORY_DAYS, 0, 3650)
    end
    -- [0913] 峰速窗口长度/切断间隙：原先写死在 lua 里、schema 改不动，现开放。
    if env.peak_window_ms == nil then
        env.peak_window_ms = bounded_int(config, "input_stats/peak_window_ms",
            PEAK_WINDOW_MS, 3000, 60000)
    end
    if env.peak_gap_ms == nil then
        env.peak_gap_ms = bounded_int(config, "input_stats/peak_gap_ms",
            PEAK_GAP_MS, 1000, 30000)
    end
    if env.peak_key_prefix == nil then
        env.peak_key_prefix = peak_key_prefix(env.peak_window_ms)
    end
    -- 以下仅在首次初始化时执行（避免每键重置速度窗口/flush 计时）
    if not env.initialized then
        env.pending_stats = env.pending_stats or {}
        env.pending_characters = env.pending_characters or 0
        env.stats_db_error = nil
        env.last_flush_ts = os.time()
        if env.last_observed_input == nil then env.last_observed_input = "" end
        env.titles = nil
        if not env.average_sample then env.average_sample = {} end
        if not env.peak_sample then env.peak_sample = {} end
        reset_sample(env.average_sample)
        reset_sample(env.peak_sample)
        env.initialized = true
    end
    -- ── 面板指令：一律 "=" 触发（key_binder / punctuator / recognizer 均已放行 "="）
    -- =tj 今日   =qb 全部   =yf 七日   =yy 卅日   =yn 本年   =jq 本设备
    -- =wx 查某天（=wx20260801 / =wx202608 / =wx2026 / =wx20260101t20260201）
    -- =wk 查看段位与皮肤   =wkd[a~b] 切段位   =wkp[a~h] 切皮肤
    if env.triggers == nil then
        env.triggers = {
            today=cfg_str(config, "input_stats/triggers/today", "=tj"),
            total=cfg_str(config, "input_stats/triggers/total", "=qb"),
            week=cfg_str(config, "input_stats/triggers/week", "=yf"),
            month=cfg_str(config, "input_stats/triggers/month", "=yy"),
            year=cfg_str(config, "input_stats/triggers/year", "=yn"),
            local_total=cfg_str(config, "input_stats/triggers/local_total", "=jq"),
            history=cfg_str(config, "input_stats/triggers/history", "=wx"),
        }
    end
    -- 上屏回调注册（幂等）：key_counter 的 processor 侧负责转接 commit_notifier，
    -- 这里只把「on_commit + translator 的 env」交给它。translator 的 env 与 processor
    -- 的 env 不是同一张表，所以必须走这套转接，不能各挂各的通知（会同一次上屏通知两遍）。
    if ok_key_counter and key_counter.set_commit_handler and not env._kc_bound then
        env._kc_bound = true
        key_counter.set_commit_handler(function(context) on_commit(context, env) end)
    end
    -- 段位主题 + 进度条皮肤（状态文件持久化，=wkd / =wkp 切换）
    if env.title_theme == nil then
    env.title_theme = config:get_string("input_stats/title_theme")
    if not env.title_theme or env.title_theme == "" then
        local saved = read_text_file(user_data_dir() .. TITLE_THEME_FILE)
        env.title_theme = saved and saved:match("^%s*(%S+)%s*$") or DEFAULT_TITLE_THEME
    end
    if not TITLE_THEMES[env.title_theme] then env.title_theme = DEFAULT_TITLE_THEME end
    local skin = tonumber(read_text_file(user_data_dir() .. SKIN_FILE) or "") or DEFAULT_SKIN
    env.skin_word = (skin >= 1 and skin <= #skinList) and skin or DEFAULT_SKIN
    end
end

local function init(env)
    ensure_env(env)
    if acquire_db(env) then migrate_database(env) end
    -- 上屏通知的挂载点：优先由 key_counter 的 processor 侧转接（见 key_counter.M.init）。
    -- 只有在 key_counter 不可用（未挂载 processor）时，才由 translator 自己连一条，
    -- 否则同一次上屏会收到两次通知 → 计数翻倍。
    if ok_key_counter and key_counter.set_commit_handler then
        if env.stat_notifier then
            env.stat_notifier:disconnect()
            env.stat_notifier = nil
        end
    else
        if env.stat_notifier then env.stat_notifier:disconnect() end
        env.stat_notifier = env.engine.context.commit_notifier:connect(
            function(context) on_commit(context, env) end
        )
    end
end

local function fini(env)
    finish_peak(env)
    finish_average(env)
    flush_pending(env)
    env.last_observed_input = ""
    if env.stat_notifier then
        env.stat_notifier:disconnect()
        env.stat_notifier = nil
    end
    env.pending_stats, env.titles = nil, nil
    env.average_sample, env.peak_sample = nil, nil
    release_db(env)
end

-- ===== 皮肤 / 段位切换指令（全部以 "=" 触发）=====
--   =wk            查看当前段位 + 皮肤，并列出全部可选编号
--   =wkd + 字母    切段位（a = 第 1 档、b = 第 2 档 …，顺序见 TITLE_THEME_ORDER）
--   =wkp + 字母    切皮肤（a = 第 1 款、b = 第 2 款 …，顺序见 skinList）
-- 字母按上面两张表的列表顺序 1:1 对应（a→1、b→2 …）：
--   一是不会与"数字键转大写"打架（4.2 的 /01 /001 直接换成 =01/=001 会命中壹/贰），
--   二是输入中途也不会被 selector 当成选字键吃掉。
local function idx_to_letter(i)
    if type(i) ~= "number" or i < 1 or i > 26 then return nil end
    return string.char(96 + i)
end
local function letter_to_idx(c)
    if not c then return nil end
    local b = c:byte(1)
    if not b or b < 97 or b > 122 then return nil end
    return b - 96
end

local function skin_theme_command(input, env)
    if input == "=wk" then
        local cur_theme = env.title_theme or DEFAULT_TITLE_THEME
        local theme_parts = {}
        for i, key in ipairs(TITLE_THEME_ORDER) do
            theme_parts[#theme_parts + 1] = string.format("%s %s%s",
                idx_to_letter(i), THEME_LABELS[key] or key,
                (cur_theme == key) and "◀" or "")
        end
        local skin_parts = {}
        for i, skin in ipairs(skinList) do
            skin_parts[#skin_parts + 1] = string.format("%s %s%s%s",
                idx_to_letter(i), string.rep(skin.field, 5),
                string.rep(skin.empty, 5), (env.skin_word == i) and "◀" or "")
        end
        -- 面板统一以 "※" 开头：on_commit 靠它识别"这是机器生成的文本"，
        -- 即使被误上屏也直接丢弃，不会记成一次真实上屏。
        local lines = {
            "※ 段位（=wkd+字母）：" .. table.concat(theme_parts, "　"),
            "   皮肤（=wkp+字母）：",
        }
        for i = 1, #skin_parts, 4 do
            local chunk = {}
            for j = i, math.min(i + 3, #skin_parts) do
                chunk[#chunk + 1] = skin_parts[j]
            end
            lines[#lines + 1] = "   " .. table.concat(chunk, "　")
        end
        return table.concat(lines, "\n")
    end
    local theme_letter = input:match("^=wkd([a-z])$")
    if theme_letter then
        local n = letter_to_idx(theme_letter)
        local key = n and TITLE_THEME_ORDER[n]
        if not key then
            return "※ 段位编号只有 =wkd" .. idx_to_letter(1) .. "~=wkd"
                .. idx_to_letter(#TITLE_THEME_ORDER)
        end
        env.title_theme = key
        write_text_file(user_data_dir() .. TITLE_THEME_FILE, key)
        env.titles = nil
        ensure_titles(env)
        return "※ 已切换段位：" .. idx_to_letter(n) .. " " .. (THEME_LABELS[key] or key)
    end
    local skin_letter = input:match("^=wkp([a-z])$")
    if skin_letter then
        local n = letter_to_idx(skin_letter)
        if not n or n < 1 or n > #skinList then
            return "※ 皮肤编号只有 =wkp" .. idx_to_letter(1) .. "~=wkp" .. idx_to_letter(#skinList)
        end
        env.skin_word = n
        write_text_file(user_data_dir() .. SKIN_FILE, tostring(n))
        return "※ 已切换皮肤：" .. idx_to_letter(n) .. " "
            .. string.rep(skinList[n].field, 5) .. string.rep(skinList[n].empty, 5)
    end
    return nil
end

local function translator(input, seg, env)
    ensure_env(env)
    observe_input_activity(env, input)
    -- 皮肤/段位指令优先处理
    local skin_msg = skin_theme_command(input, env)
    if skin_msg then
        if ok_key_counter and key_counter.reset then key_counter.reset() end
        return yield_msg(seg, skin_msg, "🎨")
    end
    -- 指令输入的按键清理已下沉到 key_counter 的 processor 里（它能拿到"还没进输入串"的
    -- 那一下按键，比 translator 更早、覆盖更全），这里不再逐键 reset，
    -- 免得把 =wx 数字守卫刚推进输入串的数字又清掉。
    local title, subtitle, start_day, end_day, device_id,
        speed_start_day, speed_end_day = standard_report(input, env)
    local data
    if title then
        prepare_report(env)
        data = aggregate_statistics(env, start_day, end_day, device_id,
            speed_start_day, speed_end_day)
        if not data and env.stats_db_error then
            return yield_msg(seg,
                "※ 统计数据库打开失败", "⚠️")
        end
    else
        try_flush(env)
        local history, first, second, empty_message = history_report(input, env)
        if history == false then return yield_msg(seg, first, second) end
        -- 注意：history_report 用返回值的个数区分两种情况——
        --   不是历史查询 → 只返回 nil（empty_message 也是 nil）→ 什么都不显示
        --   是历史查询但没数据 → 返回 nil, 标题, 副标题, 空提示 → 要显示空提示
        -- 只看 history == nil 会把第二种情况误当第一种，导致「该日没有记录」永远不显示。
        if history == nil and empty_message == nil then return end
        if not history and env.stats_db_error then
            return yield_msg(seg,
                "※ 统计数据库打开失败", "⚠️")
        end
        if not history then return yield_msg(seg, empty_message) end
        data, title, subtitle = history, first, second
    end
    -- 指令面板显示时清空待取击键：确认当前输入是 = 指令并出了面板，
    -- 就把这一串指令键整体作废，绝不残留进下一次真实上屏的码长。
    if ok_key_counter and key_counter.reset then key_counter.reset() end
    yield(Candidate("stat", seg.start, seg._end,
        format_summary(title, subtitle, data, env), "📖"))
end

return {init=init, func=translator, fini=fini}