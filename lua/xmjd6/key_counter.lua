-- key_counter.lua — 内存版击键计数器（键道6 / xmjd6 专用）
--
-- 挂载（必须是 engine.processors 第一行，才能看到所有按键）：
--     - lua_processor@*xmjd6/key_counter
--
-- 与「码长击键计数器 4.2」的差异：
--   1) 内存通道：不再读写 kc_count.txt / kc_total.txt / kc_last.txt。每键磁盘写入
--      从 2 次降为 0 次。
--   2) 只统计「键道编码键」与「提交类按键」；其余按键（翻页 -/=、方向键、调频 0、
--      开关键 %#$*&、?、F6、功能键…）一律不计数。4.2 是「除白名单外一切按键都
--      算编码键」，在键道6 会把翻页键、以词定字全记进码长，必须按本方案键位重建。
--   3) 删除 4.2 静态表里的 SELECT_KEYS[0x3b]（分号=次选键）。键道6 的 ; 属于
--      speller/alphabet 与 topup_with，是高频编码/韵码键、也是快符前缀，不是次选键。
--   4) 用 key_event:release() 过滤松键（4.2 用 modifier 位运算），并补 ascii_mode
--      过滤，避免西文模式下打的字母被算成码长。
--   5) 「= 指令输入的按键」在 processor 侧逐键作废（input 以 "=" 开头即 reset，
--      该键不计数）。指令键不会产生上屏，不清理就会残留、污染下一次真实上屏的码长；
--      下沉到 processor 是为了不打扰下面的数字守卫。
--   6) 附带「=rq 日期查询数字守卫」：带候选时按 1~9 会被 selector 当成选中候选，
--      导致查询日期首位数字被吃掉（如 =rq19910501）。命中历史查询前缀时，数字
--      直接推进输入串并吞掉按键（kAccepted），保证数字一定进入编码串。
--
-- 记录类型（与面板口径一致）：
--   "1" 编码键   "2" 退格键   "3" 被退格删掉的码   "4" 选字/提交键

local M = {}

local kAccepted = 1
local kNoop = 2

local XK_BACKSPACE = 0xff08
local XK_ESCAPE = 0xff1b

-- 历史查询触发器默认值；init/首次调用时从 input_stats/triggers/history 读取覆盖
local HISTORY_TRIGGER_DEFAULT = "=rq"

-- 提交类按键：会直接上屏或选定候选的键（本方案键位，见 xmjd6.schema.yaml key_binder）
--   空格 / 回车 / Tab(次选, key_binder send:2) / [ ](以词定字) / \(add_ge) / |(辫子)
--   /(有候选时打开文本加工面板并上屏)
-- 不列入的键（不产生上屏，不予计数）：- =(翻页) 0(动态调频) ?(词库查询)
--   % # $ * &(各种开关) 方向键/翻页键/F6/功能键 等
local COMMIT_KEYS = {
    [0x20] = true,   -- 空格
    [0xff0d] = true, -- 回车
    [0xff09] = true, -- Tab
    [0x5b] = true,   -- [
    [0x5d] = true,   -- ]
    [0x5c] = true,   -- \
    [0x7c] = true,   -- |
    [0x2f] = true,   -- /
}

-- ══════════════════════════════════════
-- 全部可变状态放在 _G 上的**单一状态表**里，绝不能放模块级局部变量。
--
-- 原因：librime-lua 每创建一个组件都会清掉 package.loaded 里的模块缓存再 require，
-- 所以 processor（lua_processor@*xmjd6/key_counter）与 translator
-- （input_statistics.lua 里的 require("xmjd6.key_counter")）**很可能拿到两份模块副本**。
-- 若把 pending/total 放模块局部变量：processor 在自己的副本里计数，translator 从
-- 自己的副本里 take() → 永远取到 0，计数器彻底失联（本方案的 typing_stats.lua
-- 长期用 _G.__typing_stats 就是这个道理）。
-- 状态表一旦建立就常驻内存（≈ 几十字节 + 每次上屏的临时序列），进程退出即释放。
-- ══════════════════════════════════════
local function state()
    local st = _G.__xmjd6_key_counter_state
    if not st then
        st = {
            pending = {},          -- 本次上屏尚未结算的按键类型序列
            total_keys = 0,        -- 累计按键数（只增不减，面板「键数」与挂载检测用）
            commit_handler = nil,  -- input_statistics 注册的上屏回调
            history_trigger = nil, -- 历史查询前缀（默认 =rq）
        }
        _G.__xmjd6_key_counter_state = st
    end
    return st
end

local function bump(kind)
    local st = state()
    st.pending[#st.pending + 1] = kind
    st.total_keys = st.total_keys + 1
end

-- 有效退格：把最后一个未消费的编码键 "1" 改成 "3"（被删码），再追加 "2"（退格键）
-- 空删（没有未消费的码）：不计入，与 4.2 一致
local function backspace_bump()
    local st = state()
    local pending = st.pending
    local last = nil
    for i = #pending, 1, -1 do
        if pending[i] == "1" then last = i break end
    end
    if not last then return end
    pending[last] = "3"
    pending[#pending + 1] = "2"
    st.total_keys = st.total_keys + 1
end

local function get_option(context, name)
    local ok, value = pcall(function() return context:get_option(name) end)
    return ok and value == true
end

local function has_candidate(context)
    local ok, cand = pcall(function() return context:get_selected_candidate() end)
    return ok and cand ~= nil
end

-- 输入串是否处于「历史查询」模式（=rq20260801 / =rq19910501）
local function is_history_query(input)
    local trigger = state().history_trigger
    if not trigger or trigger == "" or not input or input == "" then return false end
    return input:sub(1, #trigger) == trigger
end

local function load_history_trigger(env)
    local st = state()
    if st.history_trigger then return end
    local config = env and env.engine and env.engine.schema and env.engine.schema.config
    if config then
        local ok, value = pcall(function()
            return config:get_string("input_stats/triggers/history")
        end)
        if ok and type(value) == "string" and value ~= "" then
            st.history_trigger = value
            return
        end
    end
    st.history_trigger = HISTORY_TRIGGER_DEFAULT
end

-- ===== processor 入口：每个物理按键调用一次，永远放行（kNoop），只有数字守卫会吞键 =====
function M.func(key_event, env)
    if not key_event then return kNoop end
    -- 松键（小狼毫会 keydown + keyup 各调一次）：不计数
    if key_event:release() then return kNoop end
    if key_event:ctrl() or key_event:alt() or key_event:super() then return kNoop end

    local context = env and env.engine and env.engine.context
    if not context then return kNoop end
    load_history_trigger(env)

    local ch = key_event.keycode or 0

    -- 非可见字符：只处理退格 / Esc / 小键盘数字
    if ch < 0x20 or ch >= 0x7f then
        if ch == XK_BACKSPACE then
            backspace_bump()
        elseif ch == XK_ESCAPE then
            M.reset()  -- Esc：丢弃当前输入，连同未上屏的码一起作废
        elseif ch >= 0xffb0 and ch <= 0xffb9 then
            bump("4")  -- 小键盘数字：key_binder send: 0~9 → 选字
        end
        return kNoop
    end

    -- 西文模式不统计（原 4.2 缺这一层，会把英文输入算进码长）
    if get_option(context, "ascii_mode") then return kNoop end

    local input = context.input or ""

    -- 指令输入（=tj / =jt / =rq20260801 / =wkpa …）：
    -- 这些键不属于任何一次"上屏"，逐键作废，绝不会残留进下一次真实上屏的码长。
    -- 放在这里（而不是 translator 侧）的原因：
    --   a) translator 每键都会 reset，会把数字守卫刚推进输入串的数字一并清掉；
    --   b) processor 能拿到"按键尚未写进输入串"的那一瞬间，判定更干净。
    if input:sub(1, 1) == "=" then
        M.reset()
        -- =rq 日期查询数字守卫：输入串已是历史查询前缀时，数字必须直接进输入串，
        -- 否则会被 selector 当成"选中第 N 个候选"吃掉（如 =rq19910501 的首位 1）。
        -- 吞掉按键（kAccepted），且不计数——整串指令键稍后会被整体丢弃。
        if ch >= 0x30 and ch <= 0x39 and is_history_query(input) then
            context:push_input(string.char(ch))
            return kAccepted
        end
        return kNoop
    end

    -- 编码键：speller/alphabet = "zyxwvutsrqponmlkjihgfedcba;'"
    if (ch >= 0x41 and ch <= 0x5a)      -- A-Z
        or (ch >= 0x61 and ch <= 0x7a)  -- a-z
        or ch == 0x3b                   -- ;
        or ch == 0x27 then              -- '
        bump("1")
        return kNoop
    end

    -- 提交类按键
    if COMMIT_KEYS[ch] then
        bump("4")
        return kNoop
    end

    -- 数字：0 在本方案是动态调频热键（candidate_order/hotkey: 0），
    -- 有候选时不产生上屏，不计入；其余 1~9 为选字键
    if ch >= 0x30 and ch <= 0x39 then
        if ch == 0x30 and has_candidate(context) then return kNoop end
        bump("4")
        return kNoop
    end

    -- 其余按键（翻页 -/=、开关键、?、方向键、功能键等）：不计数
    return kNoop
end

-- ===== 供 input_statistics（translator）调用的接口 =====

-- 取走本次上屏的按键统计并清零
-- 返回：总键数, 退格次数, 最后一个键的类型
function M.take()
    local st = state()
    local pending = st.pending
    local n = #pending
    if n == 0 then return 0, 0, nil end
    local backspaces = 0
    for i = 1, n do
        if pending[i] == "2" then backspaces = backspaces + 1 end
    end
    local last_type = pending[n]
    st.pending = {}
    return n, backspaces, last_type
end

-- 清空待取计数（指令模式/面板上屏时调用，防残留污染下一次上屏）
function M.reset()
    state().pending = {}
end

-- 顶功归还：顶屏时最后那个编码键属于下一个字，写回一个 "1"
function M.restore_last()
    local st = state()
    st.pending[#st.pending + 1] = "1"
end

-- 累计击键数（只增不清）
function M.count()
    return state().total_keys
end

-- 挂载检测：计数器至少工作过一次
function M.status()
    return state().total_keys > 0 and 1 or 0
end

-- 注册上屏回调（由 input_statistics 首次运行时注册，携带 translator 的 env）
function M.set_commit_handler(fn)
    state().commit_handler = type(fn) == "function" and fn or nil
end

-- 上屏通知必须挂在 processor 的 init 上：
-- 部分桌面 librime-lua（小狼毫）不调用 translator 的 init，挂在 translator 上会收不到通知。
-- handler 每次都从状态表实时取，因此与「注册方是哪个模块副本」无关。
function M.init(env)
    load_history_trigger(env)
    local context = env and env.engine and env.engine.context
    if context and context.commit_notifier then
        if env.commit_connection then
            pcall(function() env.commit_connection:disconnect() end)
        end
        env.commit_connection = context.commit_notifier:connect(function(c)
            local handler = state().commit_handler
            if handler then pcall(handler, c) end
        end)
    end
end

function M.fini(env)
    if env and env.commit_connection then
        pcall(function() env.commit_connection:disconnect() end)
        env.commit_connection = nil
    end
    -- 不清 pending / total_keys：重新部署后累计键数应延续，指令键也不会跨会话残留污染
end

-- 跨组件认领用的句柄（input_statistics 用它判断"key_counter 能不能用"）。
-- 注意：真正的数据共享靠 _G.__xmjd6_key_counter_state，不靠这个表本身。
_G.__xmjd6_key_counter = M

return M
