-- typing_stats.lua
-- 打字统计：按天聚合记录汉字数、击键数、上屏次数、退格数、活跃打字秒数与计速字数，
-- =tj 查看今日 / 近7天 / 累计的字数、码长（击键÷字数）、退格与打字速度。
-- 速度 = 计速字数 ÷ 活跃时长。两者从同一时刻起配对累计（活跃时长按相邻按键
-- 间隔 ≤ IDLE_GAP 秒累加、每段打字另计 1 秒起步，计速字数只含时长记录期间
-- 上屏的字），避免分子含无时长记录的旧字导致速度虚高。速度属估算值，显示带
-- "约"；统计范围内存在未计速的字（旧数据）时另加小字"（可能不准）"。
--
-- 存储：user_data_dir/typing_stats.txt，每天固定一行（当日行原地累加，非流水日志），
-- 仅保留最近 MAX_DAYS 行，文件大小恒定在几十 KB 以内。
-- 写盘策略：内存累计，每 FLUSH_EVERY 次上屏或距上次写盘超 FLUSH_IDLE 秒时落盘；
-- iOS 键盘收起时经 mem_cleaner 落盘并释放历史缓存（重新打开时懒加载）。

local mem_cleaner = require("xmjd6.mem_cleaner")

local M = {}

local kNoop = 2

local STATS_FILE = "typing_stats.txt"
local MAX_DAYS = 730
local FLUSH_EVERY = 20 -- 每 N 次上屏落盘一次
local FLUSH_IDLE = 60  -- 距上次落盘超过 N 秒也落盘

local XK_BACKSPACE = 0xff08

local IDLE_GAP = 5        -- 相邻按键间隔超过 N 秒视为停顿，不计入活跃打字时长
local MIN_SPEED_SECS = 30 -- 活跃时长不足 N 秒不显示速度，样本太小没有意义

local function state()
    if not _G.__typing_stats then
        _G.__typing_stats = {
            loaded = false,
            history = nil, -- 已落盘的历史行（不含今日）：{day, chars, keys, commits, backspaces, sent_chars}
            today = nil,   -- 今日累计行
            dirty = 0,
            last_flush = 0,
            last_key_time = nil, -- 上一次计键时刻，用于估算活跃打字时长
        }
    end
    return _G.__typing_stats
end

local function stats_path()
    return rime_api.get_user_data_dir() .. "/" .. STATS_FILE
end

local function today_str()
    return os.date("%Y-%m-%d")
end

local function new_row(day)
    -- sent_chars 为旧版"连打字数"，已停止累计，仅为兼容旧文件保留列位
    return { day = day, chars = 0, keys = 0, commits = 0, backspaces = 0,
        sent_chars = 0, active_secs = 0, timed_chars = 0 }
end

local function load(st)
    if st.loaded then return end
    st.history = {}
    st.today = nil
    local today = today_str()
    local f = io.open(stats_path(), "r")
    if f then
        for line in f:lines() do
            local day, c, k, cm, b, s, a, tc =
                line:match("^(%d%d%d%d%-%d%d%-%d%d)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t?(%d*)\t?(%d*)")
            if day then
                -- 旧 6 列文件无时长列；7 列过渡格式只有时长没有配对的计速字数，
                -- 用它算速度会虚高，时长一并作废，从 8 列格式起重新累计
                local timed = tonumber(tc)
                local secs = timed and (tonumber(a) or 0) or 0
                local row = {
                    day = day,
                    chars = tonumber(c) or 0,
                    keys = tonumber(k) or 0,
                    commits = tonumber(cm) or 0,
                    backspaces = tonumber(b) or 0,
                    sent_chars = tonumber(s) or 0,
                    active_secs = secs,
                    timed_chars = timed or 0,
                }
                if day == today then
                    st.today = row
                else
                    st.history[#st.history + 1] = row
                end
            end
        end
        f:close()
    end
    st.today = st.today or new_row(today)
    st.loaded = true
end

local function flush(st)
    if not st.loaded then return end
    -- 裁剪：历史 + 今日合计不超过 MAX_DAYS 行（文件按日期序追加，行序即日期序）
    while #st.history >= MAX_DAYS do
        table.remove(st.history, 1)
    end
    local f = io.open(stats_path(), "w")
    if not f then return end
    local function write_row(r)
        f:write(r.day, "\t", r.chars, "\t", r.keys, "\t", r.commits, "\t",
            r.backspaces, "\t", r.sent_chars or 0, "\t", r.active_secs or 0, "\t",
            r.timed_chars or 0, "\n")
    end
    for _, row in ipairs(st.history) do write_row(row) end
    write_row(st.today)
    f:close()
    st.dirty = 0
    st.last_flush = os.time()
end

-- 跨天：把旧的今日行归入历史，开新行
local function roll_day(st)
    local today = today_str()
    if st.today.day ~= today then
        st.history[#st.history + 1] = st.today
        st.today = new_row(today)
        flush(st)
    end
end

local function count_han(text)
    local n = 0
    local ok = pcall(function()
        for _, cp in utf8.codes(text) do
            if (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) then
                n = n + 1
            end
        end
    end)
    if not ok then return 0 end
    return n
end

local function is_ascii_mode(env)
    local ctx = env and env.engine and env.engine.context
    if not ctx then return false end
    local ok, v = pcall(function() return ctx:get_option("ascii_mode") end)
    return ok and v == true
end

-- 计键 processor：始终 kNoop 透传，必须挂在所有可能吞键的 processor 之前
function M.processor(key, env)
    if not key or key:release() or key:ctrl() or key:alt() or key:super() then
        return kNoop
    end
    if is_ascii_mode(env) then return kNoop end

    local code = tonumber(key.keycode or 0) or 0
    local is_backspace = (code == XK_BACKSPACE)
    if not is_backspace and not (code >= 0x20 and code < 0x7f) then return kNoop end

    local st = state()
    load(st)
    roll_day(st)

    -- 活跃时长：相邻按键间隔在 IDLE_GAP 秒内按实际间隔累计；首键或长停顿后
    -- 视为新一段打字，按 1 秒起步成本计。os.time() 只有秒级精度，聊天式的
    -- 短爆发若只记"首键到末键"跨度会严重少记时间、速度虚高
    local now = os.time()
    local gap = st.last_key_time and (now - st.last_key_time) or -1
    if gap >= 0 and gap <= IDLE_GAP then
        st.today.active_secs = st.today.active_secs + gap
    else
        st.today.active_secs = st.today.active_secs + 1
    end
    st.last_key_time = now

    if is_backspace then
        st.today.backspaces = st.today.backspaces + 1
    else
        st.today.keys = st.today.keys + 1
    end
    return kNoop
end

function M.on_commit(ctx)
    local st = state()
    if not st.loaded then return end -- 没打过键就 commit（如外部调用），不计
    local text = ""
    local ok, t = pcall(function() return ctx:get_commit_text() end)
    if ok then text = tostring(t or "") end
    if text == "" then return end

    roll_day(st)
    local han = count_han(text)
    st.today.commits = st.today.commits + 1
    st.today.chars = st.today.chars + han
    -- 计速字数与活跃时长同期累计，保证速度的分子分母来自同一段时间
    st.today.timed_chars = (st.today.timed_chars or 0) + han

    st.dirty = st.dirty + 1
    if st.dirty >= FLUSH_EVERY or os.time() - (st.last_flush or 0) >= FLUSH_IDLE then
        flush(st)
    end
end

function M.init_processor(env)
    local ctx = env and env.engine and env.engine.context
    if ctx and ctx.commit_notifier then
        -- 保存 connection 以便 fini 中 disconnect，避免重新部署时累积旧 handler
        env.commit_connection = ctx.commit_notifier:connect(function(c)
            pcall(M.on_commit, c)
        end)
    end
    mem_cleaner.register(function()
        local st = state()
        flush(st)
        st.loaded = false
        st.history = nil
        st.today = nil
    end)
end

function M.fini_processor(env)
    if env.commit_connection then
        pcall(function() env.commit_connection:disconnect() end)
        env.commit_connection = nil
    end
    flush(state())
end

local function sum_rows(rows, from_day)
    local acc = new_row("")
    for _, r in ipairs(rows) do
        if not from_day or r.day >= from_day then
            acc.chars = acc.chars + r.chars
            acc.keys = acc.keys + r.keys
            acc.commits = acc.commits + r.commits
            acc.backspaces = acc.backspaces + r.backspaces
            acc.active_secs = acc.active_secs + (r.active_secs or 0)
            acc.timed_chars = acc.timed_chars + (r.timed_chars or 0)
        end
    end
    return acc
end

local function code_len(r)
    if r.chars == 0 then return "-" end
    return string.format("%.2f", r.keys / r.chars)
end

-- 速度 = 计速字数 ÷ 活跃时长。活跃时长是估算值，一律带"约"；
-- 范围内有未计速的字（旧数据）时速度只代表有记录部分，加注"（可能不准）"。
local function speed_str(r)
    local secs = r.active_secs or 0
    local timed = r.timed_chars or 0
    if secs < MIN_SPEED_SECS or timed == 0 then return "-" end
    local s = string.format("约%d字/分", math.floor(timed / secs * 60 + 0.5))
    if timed < r.chars then
        s = s .. "（可能不准）"
    end
    return s
end

function M.translator(input, seg, env)
    if input ~= "=tj" then return end
    local st = state()
    load(st)
    roll_day(st)

    local all = {}
    for _, r in ipairs(st.history) do all[#all + 1] = r end
    all[#all + 1] = st.today

    local week_from = os.date("%Y-%m-%d", os.time() - 6 * 86400)
    local rows = {
        { "今日", st.today },
        { "近7天", sum_rows(all, week_from) },
        { "累计", sum_rows(all, nil) },
    }
    local first_day = st.history[1] and st.history[1].day or st.today.day
    for i, item in ipairs(rows) do
        local label, r = item[1], item[2]
        local text = string.format("%s %d 字 · 码长 %s", label, r.chars, code_len(r))
        local comment = string.format("击键 %d · 上屏 %d · 退格 %d · 速度 %s",
            r.keys, r.commits, r.backspaces, speed_str(r))
        if label == "累计" then
            comment = comment .. " · 自 " .. first_day
        end
        local cand = Candidate("stats", seg.start, seg._end, text, comment)
        cand.quality = 600000 - i
        yield(cand)
    end
end

return M
