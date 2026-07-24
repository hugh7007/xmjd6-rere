-- typing_stats.lua
-- 打字统计：按天聚合记录汉字数、击键数、上屏次数、退格数、连打字数，
-- =stats 查看今日 / 近7天 / 累计的字数、码长（击键÷字数）、退格与连打占比。
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

local function state()
    if not _G.__typing_stats then
        _G.__typing_stats = {
            loaded = false,
            history = nil, -- 已落盘的历史行（不含今日）：{day, chars, keys, commits, backspaces, sent_chars}
            today = nil,   -- 今日累计行
            dirty = 0,
            last_flush = 0,
            last_head_apostrophe = false, -- 最近一次按键时 input 是否 ' 开头（连打态快照）
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
    return { day = day, chars = 0, keys = 0, commits = 0, backspaces = 0, sent_chars = 0 }
end

local function load(st)
    if st.loaded then return end
    st.history = {}
    st.today = nil
    local today = today_str()
    local f = io.open(stats_path(), "r")
    if f then
        for line in f:lines() do
            local day, c, k, cm, b, s =
                line:match("^(%d%d%d%d%-%d%d%-%d%d)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)")
            if day then
                local row = {
                    day = day,
                    chars = tonumber(c) or 0,
                    keys = tonumber(k) or 0,
                    commits = tonumber(cm) or 0,
                    backspaces = tonumber(b) or 0,
                    sent_chars = tonumber(s) or 0,
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
            r.backspaces, "\t", r.sent_chars, "\n")
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
    local st = state()
    if code == XK_BACKSPACE then
        load(st)
        roll_day(st)
        st.today.backspaces = st.today.backspaces + 1
        return kNoop
    end
    if code >= 0x20 and code < 0x7f then
        load(st)
        roll_day(st)
        st.today.keys = st.today.keys + 1
        local ctx = env and env.engine and env.engine.context
        local input = ctx and tostring(ctx.input or "") or ""
        st.last_head_apostrophe = (input:sub(1, 1) == "'")
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
    -- 连打判定：commit 瞬间 input 仍为 ' 开头，或最近按键快照处于连打态
    local input = tostring(ctx.input or "")
    if han > 0 and (input:sub(1, 1) == "'" or st.last_head_apostrophe) then
        st.today.sent_chars = st.today.sent_chars + han
    end
    st.last_head_apostrophe = false

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
            acc.sent_chars = acc.sent_chars + r.sent_chars
        end
    end
    return acc
end

local function code_len(r)
    if r.chars == 0 then return "-" end
    return string.format("%.2f", r.keys / r.chars)
end

local function pct(part, total)
    if total == 0 then return "0%" end
    return string.format("%d%%", math.floor(part / total * 100 + 0.5))
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
        local comment = string.format("击键 %d · 上屏 %d · 退格 %d · 连打 %s",
            r.keys, r.commits, r.backspaces, pct(r.sent_chars, r.chars))
        if label == "累计" then
            comment = comment .. " · 自 " .. first_day
        end
        local cand = Candidate("stats", seg.start, seg._end, text, comment)
        cand.quality = 600000 - i
        yield(cand)
    end
end

return M
