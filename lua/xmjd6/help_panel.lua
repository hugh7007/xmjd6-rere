-- help_panel.lua
-- =? / ojd 功能帮助面板：**清单数据 + 按键接管合并在本文件**（2026-09-14 起单一文件）。
--   原 help_items.lua 已并入本文件上半部分，不再单独存在 —— 它原本同时被本处理器
--   与 xmjd6_tools.lua（translator）require，合并后两者都从本模块取 `M.items`。
--
-- ══════════════════════════════════════════════════════════════════
-- 一、清单数据（原 help_items.lua）
-- ══════════════════════════════════════════════════════════════════
-- =? / ojd 功能帮助面板的数据源（单一定义点）：
--   xmjd6_tools.lua  → 从起始页全量输出（前端原生分页 / 桌面改输入串）；每个页首行带【第n页/共m页】
--   本文件下半部分    → 空格 / 数字直选时据此把输入串替换为触发码
--
-- 条目格式：{ 显示文本, 说明, 触发码 }
--   触发码为 nil → 纯文档型条目（需要真实上文才能用，如「打字后按 ?」），
--                 面板中空格/数字保持原生行为：上屏说明文字。
--   触发码非空 → 面板中空格/数字直选会真正切到该功能。
--
-- 顺序即面板显示顺序（2026-09-14 用户自定义第四版，共 42 条 / 9 页）。
-- ⚠️ 显示文本必须唯一：本文件按下文的 trigger_of() 按文本反查触发码。
-- ⚠️ 改动条数/顺序后要同步改 scripts/smoke_help_panel.lua 的条目数与页码/索引断言。
--
-- ══════════════════════════════════════════════════════════════════
-- 二、按键接管
-- ══════════════════════════════════════════════════════════════════
--   = 或 .   → 下一页；- 或 ,  → 上一页（翻页键在面板内被本处理器吞掉，
--             不再依赖 key_binder —— direct_ascii 的符号直上屏排在 key_binder 之前，
--             原生 Page_Up/Page_Down 绑定在这个面板里到不了位）
--   空格      → 仅 **第 1 页首行** 关闭面板（清空输入串，不上屏）；
--               其余页任意行执行该行对应的功能（把输入串替换为该项触发码，
--               文档型条目不接管、原生上屏说明文字）
--   数字 1~5  → 执行当页第 N 项对应的功能
--   回车      → 原生行为：把当前输入串（=? / ojd）当字母直接上屏（本处理器不接管）
--
-- 翻页键共三类：
--   ① - , 与 Page_Up      → 上一页（无条件）
--   ② = . 与 Page_Down    → 下一页（无条件）
--   ③ ↑ / ↓               → 仅在高亮位于当页首行 / 末行时翻页（其余情况放行给 selector
--                            移动高亮，故当页内仍可用箭头逐行选择，符合常规输入法习惯）
--   手机（仓输入法 swipePaging: true）滑动翻页由前端在 UI 层直接翻菜单页，**不走按键** ——
--   这类翻页本处理器看不到，所以 xmjd6_tools.lua 必须全量输出候选（菜单才有页可翻）；
--   本处理器负责的只是「本地键盘上的翻页键」，并保证前端自翻页后行号语义仍然正确。
--
-- 翻页实现：起始页状态编码在输入串尾（base + 若干个 =，净页偏 = 起始页-1），
-- 改写输入串触发重新翻译，xmjd6_tools.lua 从该起始页全量输出候选。
-- base = =? 或 ojd；只依赖 ctx.input 赋值（text_transform.lua 先例），
-- pcall 失败回退 ctx:clear() + ctx:push_input()。
--
-- ⚠️ 行号语义（2026-09-14 修正）：引擎的 seg.selected_index 与 seg:get_candidate_at(i)
-- 都是**菜单内绝对下标**（先例：text_transform.lua 用 floor(selected_index / page_size)
-- 求「当前页起始绝对下标」，再 page_start + local_index 取页内第 n 个候选）。
-- 桌面端菜单自起始页起、前端恒停在菜单第 1 页，绝对下标恰好等于显示行号，旧代码直接拿它
-- 当行号也能用；手机端前端原生翻页后菜单仍停在第 N 页，此时必须先把绝对下标还原成
-- 「菜单内页号 + 页内行」，否则「数字直选 / 空格执行」会打到起始页前几行上
-- （翻到第 3 页按 2，结果执行了第 1 页第 2 项）。page_and_row() 负责这个还原。
--
-- 仅当输入串匹配 ^(=?|ojd)[-=]*$ 时接管按键，其余一律放行；
-- 文档型条目（清单中无触发码）不接管，保持原生「上屏说明文字」行为。
--
-- 挂载位置（xmjd6.schema.yaml / engine/processors）：key_counter 之后——
--   早于 direct_ascii / quick_symbol / punctuator 等，保证 =/-/,/. 与空格数字最先到达。

local kAccepted = 1
local kNoop = 2

local M = {}

-- ══════════ 清单数据（原 help_items.lua，42 条 / 9 页）══════════
local ITEMS = {
    { "=? / ojd", "功能帮助：可用 - = , . 翻页", "=?" },
    { "=tj", "打字统计（今天）", "=tj" },
    { "a模式是临时长句子模式", "前缀 a，断字是一次空格，上屏是两次空格）", "a" },
    { "'+编码+空格", "1.a模式刚刚上屏词语，2.'+编码完成自造词。", "'" },
    { "'+2/3/4'+编码;", "把前几次上屏内容加入自造词，2表示最近多少次", "'" },
    { "''+编码;", "精确删除刚刚上屏的内容，未上屏的不能删：''+编码", "''" },
    { "'''", "自造词批量管理：三个单引号后列出全部，上下选中后继续按 ' 删除", "'''" },
    { "dje rq xq ej nl", "倒计时 / 日期 / 时间 / 星期 / 农历", "dje" },
    { "=qb =yf =yy =yn", "打字统计：全部 / 7天 / 30天 / 365天", "=qb" },
    { "=wk", "更换文字皮肤=wk+a-h", "=wk" },
    { "=1+1", "计算器：Lua 表达式、函数、链式调用", "=" },
    { "=wx20260808", "打字统计： 指定日期", "=wx" },
    { "打字后按【?】词库模糊搜索", "例如：天涯?", nil },
    { "=123", "数字 / 金额大写读法", "=" },
    { "=10km>mi", "长度：mm/cm/m/km/in/ft/yd/mi", "=" },
    { "=1kg>lb", "重量：mg/g/kg/oz/lb", "=" },
    { "=1024mb>gb", "数据容量：b/kb/mb/gb/tb（按1024换算）", "=" },
    { "=mem", "查看当前 Lua 堆内存与已注册缓存数", "=mem" },
    { "=100c>f", "温度：c/f/k", "=" },
    { "=255>16 / =16:ff>10", "二至三十六进制转换", "=" },
    { "=5~3", "按位异或：候选含十进制、十六进制、二进制", "=" },
    { "=19910501", "日历查询：公历农历干支星期互转", "=" },
    { "=join/3", "合并最近3段上屏内容，可选顿号、逗号、空格或换行", "=" },
    { "=rmb1234.56", "人民币金额大写；小数也可直接输入 =1234.56", "=" },
    { "=uuid", "UUID v4（小写 / 大写）", "=uuid" },
    { "=pw / =pw24", "随机密码：默认16位，可指定8~64位", "=pw" },
    { "=memc", "释放已注册缓存并执行 GC", "=memc" },
    { "=1718160000", "Unix 时间戳转日期时间（10/13位）", "=1718160000" },
    { "i + 英文", "英文混输：空格分词，双空格 / 回车上屏整句", nil },
    { "有候选时按 /", "加工当前候选；连打模式中加工完整句子", nil },
    { "【｜】", "辫子模式：用 ᥬ ᩤ 包裹当前候选", nil },
    { "0", "动态调频：把第二/高亮候选提到首选", nil },
    { "=tp", "调频管理：输入后列出全部调频，上下选中后按 0 撤销", "=tp" },
    { "coerr", "动态调频：查看 candidate_order.txt 解析错误", "coerr" },
    { "\\abc123", "字符工具：数学斜体小写", "\\abc123" },
    { "\\\\abc123", "字符工具：数学斜体大写", "\\\\abc123" },
    { "\\\\\\abc", "字符工具：无衬线粗体", "\\\\\\abc" },
    { "&62fc", "Unicode 码点查字，候选含相邻码点", "&62fc" },
    { "u + 全拼", "全拼反查键道编码；知道读音但不知字根怎么打时用 u+全拼，再翻页查看", nil },
    { "v + 两分", "两分 / 拆字反查：不知读音也不知字根、但知道怎么写时用 v，如 愆vyfxb、嘦vfkyz、姕vcknl", nil },
    { "` + 编码", "万能符：不知读音但知道键道字根时，用 ` 替换不记得的字母，如 `a→滨、`i→摈", nil },
    { "o + 编码", "GBK 全字集查询：不知读音也可用 o + 笔画（a 折、v 横、i 竖、u 撇、o 点/捺）", nil },
    { "=o / =oc / =ol / =os", "应用启动器：打开计算器 / 日历 / 系统设置", "=o" },
}

-- 对外暴露：xmjd6_tools.lua（translator）与 smoke_help_panel.lua 都从这里取清单。
M.items = ITEMS

-- 按显示文本查触发码（找不到或为文档型 → nil）
function M.trigger_of(display)
    for _, item in ipairs(ITEMS) do
        if item[1] == display then
            return item[3]
        end
    end
    return nil
end

-- 按显示文本查序号（1 基；找不到 → nil）
function M.index_of(display)
    for i, item in ipairs(ITEMS) do
        if item[1] == display then
            return i
        end
    end
    return nil
end

-- ══════════ 按键接管 ══════════

local KEY_SPACE = 0x20
local PAGE_UP_KEYS = { [0x2D] = true, [0x2C] = true, [0xFF55] = true }   -- - 和 , 和 Page_Up
local PAGE_DOWN_KEYS = { [0x3D] = true, [0x2E] = true, [0xFF56] = true } -- = 和 . 和 Page_Down
local ARROW_UP = 0xFF52                                                   -- ↑：高亮在首行才翻上页
local ARROW_DOWN = 0xFF54                                                 -- ↓：高亮在末行才翻下页

local function digit_of(keycode)
    if keycode >= 49 and keycode <= 57 then          -- 主键盘 '1'..'9'
        return keycode - 48
    end
    if keycode >= 0xffb1 and keycode <= 0xffb9 then  -- 小键盘 KP_1..KP_9
        return keycode - 0xffb0
    end
    return nil
end

-- 解析面板状态：返回 base（=? 或 ojd）与净页偏（#= − #-）；非面板输入返回 nil
local function panel_state(input)
    input = tostring(input or "")
    local base, marks = input:match("^(=%?)([-=]*)$")
    if not base then
        base, marks = input:match("^(ojd)([-=]*)$")
    end
    if not base then
        return nil
    end
    local _, n_eq = marks:gsub("=", "")
    local _, n_minus = marks:gsub("%-", "")
    return base, n_eq - n_minus
end

-- 单次更新替换整个输入串（text_transform.lua 的做法，避免 clear+push 两次通知）。
-- force = true：输入串内容不变时也强制重建（手机端前端自翻了页，必须靠重建菜单把显示拉回
-- 起始页，否则「上一页」会原地不动）。
local function replace_input(ctx, text, force)
    local ok = pcall(function() ctx.input = text end)
    if ok and tostring(ctx.input or "") == text and not force then
        return true
    end
    ctx:clear()
    ctx:push_input(text)
    return true
end

local function page_size(env)
    if env.help_page_size then
        return env.help_page_size
    end
    local n = 5
    pcall(function()
        local v = env.engine.schema.config:get_int("menu/page_size")
        if v and v > 0 then
            n = v
        end
    end)
    env.help_page_size = n
    return n
end

local function total_pages(env)
    return math.ceil(#ITEMS / page_size(env))
end

-- 指定页（1 基）实际行数：末页可能不满
local function rows_on_page(env, page)
    local ps = page_size(env)
    local left = #ITEMS - (page - 1) * ps
    if left < 0 then left = 0 end
    if left > ps then left = ps end
    return left
end

local function active_seg(ctx)
    local ok, comp = pcall(function() return ctx.composition:back() end)
    if ok and comp then
        return comp
    end
    return nil
end

local function highlighted_index(seg)
    local ok, idx = pcall(function() return seg.selected_index end)
    if ok and type(idx) == "number" then
        return idx
    end
    return 0
end

local function candidate_at(seg, index)
    local ok, cand = pcall(function() return seg:get_candidate_at(index) end)
    if ok then
        return cand
    end
    return nil
end

-- [0914 十一稿] 「空格关闭面板」收窄为**仅第 1 页首行**：翻页后各页首行按空格
--   照常执行该行（用户 11:41 定稿）。close_panel 仅在此特例使用。

-- 关闭面板（空格 + 第 1 页首行）：清空输入串让候选框收起，**不上屏**任何字符。
-- 为什么先手动 reset 计数：空格是 key_counter 的「提交类按键」，而 key_counter 挂在本
-- 处理器之前，已经为这次空格 bump 过一次计数；面板期间的按键本就不该算进码长 / 上屏
-- （ojd 路线的 o/j/d 还会被记成 3 个编码键）。不清掉就会漏进下一次真实上屏。
-- 状态表在 _G.__xmjd6_key_counter_state，所以拿哪一份副本都行。
local function close_panel(env)
    local kc = _G.__xmjd6_key_counter
    if kc and type(kc.reset) == "function" then
        pcall(function() kc.reset() end)
    end
    pcall(function() env.engine.context:clear() end)
    return kAccepted
end

-- 执行给定**绝对下标**对应的帮助条目：有触发码 → 替换输入串并返回 true
local function execute_abs(ctx, seg, abs)
    if not seg then
        return false
    end
    local cand = candidate_at(seg, abs)
    if not cand or cand.type ~= "tools" then
        return false
    end
    local trigger = M.trigger_of(cand.text)
    if not trigger then
        return false
    end
    replace_input(ctx, trigger)
    return true
end

-- 把「菜单内绝对下标」还原成「菜单内页号（0 基）+ 页内行（0 基）」。
-- 引擎语义见文件头 ⚠️：桌面端恒在菜单第 1 页（页号 0），手机端前端原生翻页后页号 > 0，
-- 此时 get_candidate_at 必须补上 页号 × 页大小 才能取到「显示行」对应的候选。
local function page_and_row(env, seg)
    local ps = page_size(env)
    local sel = highlighted_index(seg)
    if sel < 0 then
        sel = 0
    end
    local zero = math.floor(sel / ps)
    return zero, sel - zero * ps
end

function M.init(env)
    env.help_page_size = nil -- 首次按键时从配置读
end

function M.func(key, env)
    if key:release() then
        return kNoop
    end
    local ctx = env.engine.context
    if not ctx then
        return kNoop
    end
    local base, offset = panel_state(ctx.input)
    if not base then
        return kNoop
    end

    local ps = page_size(env)
    local pages = total_pages(env)

    -- 显示页语义：菜单内页号（0 基）+ 页内行（0 基）；手机端前端自翻页后页号 > 0（见文件头 ⚠️）
    local seg = active_seg(ctx)
    local zero, row = 0, 0
    if seg then
        zero, row = page_and_row(env, seg)
    end
    -- 当前显示页（全局 1 基）= 起始页 + 菜单内页号
    local rows = rows_on_page(env, offset + zero + 1)

    -- 翻页：=/. /Page_Down 下一页，-/, /Page_Up 上一页；页偏编码进输入串（统一归一化为若干个 =）。
    -- 目标页从**当前显示页**推进（而不是从起始页），手机端前端自翻过页后按 = 才不会跳回起始页。
    if PAGE_UP_KEYS[key.keycode] or PAGE_DOWN_KEYS[key.keycode] then
        local dir = PAGE_DOWN_KEYS[key.keycode] and 1 or -1
        local off = offset + zero + dir
        if off < 0 then off = 0 end
        if off > pages - 1 then off = pages - 1 end
        -- 起始页没变但前端已自翻页 → 输入串内容不变，必须强制重建菜单把显示拉回起始页
        replace_input(ctx, base .. string.rep("=", off), off == offset and zero > 0)
        return kAccepted
    end

    -- ↑ / ↓：高亮在显示页首行 / 末行时翻页，其余放行给 selector 移动高亮
    if key.keycode == ARROW_UP or key.keycode == ARROW_DOWN then
        if not seg then
            return kNoop
        end
        if key.keycode == ARROW_DOWN then
            if rows <= 0 or row < rows - 1 then
                return kNoop -- 当页还能往下走 → 交给 selector
            end
            local off = offset + zero + 1
            if off > pages - 1 then
                return kAccepted -- 已是末页末行，吞掉不越界
            end
            replace_input(ctx, base .. string.rep("=", off), zero > 0)
            return kAccepted
        end
        if row > 0 then
            return kNoop -- 当页还能往上走 → 交给 selector
        end
        local off = offset + zero - 1
        if off < 0 then
            return kAccepted -- 已是首页首行，吞掉不越界
        end
        replace_input(ctx, base .. string.rep("=", off), zero > 0)
        return kAccepted
    end

    -- 数字 1~页大小：执行**显示页**第 N 行（绝对下标 = 菜单内页号 × 页大小 + 行号）
    local digit = digit_of(key.keycode)
    if digit then
        if digit > ps or digit > rows then
            return kNoop -- 当页没有该序号，保持原生行为
        end
        if execute_abs(ctx, seg, zero * ps + (digit - 1)) then
            return kAccepted
        end
        return kNoop -- 文档型 / 越界 → 原生「选中并上屏说明文字」
    end

    -- 空格：仅「起始页第 1 页 + 菜单内第 1 行」（即面板总首条 =? / ojd）→ 关闭面板（保留原规则）；
    --   其余任意情况（含翻页后各页首行）→ 执行高亮行（触发码 → 替换输入串；文档型 → 原生上屏说明文字）
    -- [0914 十一稿] 用户定稿：翻页后按空格要能执行功能 / 上屏。
    --   ⚠️ 必须加 offset == 0：翻页后菜单从头渲染，zero 恒为 0，单看 zero/row 会把每页首行都误判成总首行。
    if key.keycode == KEY_SPACE then
        if seg then
            if offset == 0 and zero == 0 and row == 0 then
                -- 只有确实是本面板的候选才当「关闭」处理：menu 为空、或混进了别的候选
                -- （如 O 模式漏进来的）时保持放行，别吞掉原生行为。
                local cand = candidate_at(seg, zero * ps)
                if cand and cand.type == "tools" then
                    return close_panel(env)
                end
                return kNoop
            end
            if execute_abs(ctx, seg, zero * ps + row) then
                return kAccepted
            end
        end
        return kNoop
    end

    return kNoop
end

function M.fini(env)
end

return M
