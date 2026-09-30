-- candidate_order_processor.lua
-- Hotkey runtime candidate promotion for candidate_order.txt.
-- Default: 0. 「编码档位前移一位」—— 目标恒为**当前高亮候选**
-- （未移动光标时 = 首位候选）。被挤者补码一位；若目标本身就是短码处首位，
-- 则 displaced 自指 → 退化成纯粹的「前移 + 隐藏原码副本」。
--
-- 被挤者取「short_code 处原本的首位词」，靠 menu_first_cache 逐键记录得到；
-- ★ 只在**按下**（非 release）时记录，详见 remember_menu 上方的注释。
--
-- 另有一条不按 0 的路径：**空码自动顺延 / 级联顺延**（auto_cascade）。
-- 主路径 = 按 0 把词搬走之后，被腾空的那个码如果变成空码，就把它的「后面的一位」
-- 一起顶上来（一次按键完成整条链，用户第 9 轮要求）；
-- 兜底路径 = 非字母键（空格/数字/回车/←→…）触发，管那些历史遗留的空码。
-- 两条路共用 next_in_line()。详见下方注释。

local core = require("xmjd6.candidate_order").core

local kAccepted = 1
local kNoop = 2

_G.__candidate_order_manager_state = _G.__candidate_order_manager_state or {}

-- 惰性取名：fini 会把 _G.__candidate_order_manager_state 置 nil，
-- 重载后 processor 若先于 init 被调用，缓存的 upvalue 就会是 nil，
-- 一索引即崩（历史报错：attempt to index a nil value (upvalue 'manager_state')）。
local function state()
    local s = _G.__candidate_order_manager_state
    if type(s) ~= "table" then
        s = {}
        _G.__candidate_order_manager_state = s
    end
    return s
end

local function get_store_file(env)
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        local file = env.engine.schema.config:get_string("candidate_order/store_file")
        if file and file ~= "" then return file end
    end
    return core.default_filename
end

local function get_hotkey(env)
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        local hotkey = env.engine.schema.config:get_string("candidate_order/hotkey")
        if hotkey and hotkey ~= "" then return hotkey end
    end
    return "0"
end

local function is_ctrl_j(key)
    if not key or key:release() then return false end
    if key:ctrl() and not key:alt() and not key:super() then
        local code = key.keycode or 0
        return code == string.byte("j") or code == string.byte("J")
    end
    local repr = key:repr() or ""
    return repr == "Control+j" or repr == "Control+J" or repr == "Ctrl+j" or repr == "Ctrl+J"
end

local function is_hotkey(key, hotkey)
    if not key or key:release() then return false end
    local repr = key:repr() or ""
    local code = key.keycode or 0

    -- Keep Ctrl+j as a desktop compatibility shortcut even when the unified hotkey is 0.
    if is_ctrl_j(key) then return true end

    if hotkey == "0" then
        return (not key:ctrl() and not key:alt() and not key:super())
            and (repr == "0" or code == string.byte("0"))
    end

    if repr == hotkey then return true end
    return false
end

local function is_plain_zero(key)
    if not key or key:release() or key:ctrl() or key:alt() or key:super() then
        return false
    end
    local repr = key:repr() or ""
    return key.keycode == string.byte("0") or repr == "0"
end

local function is_plain_press(key)
    return key and not key:release() and not key:ctrl() and not key:alt() and not key:super()
end

local function management_query(input)
    if type(input) ~= "string" then return nil end
    return input:match("^=tp(.*)$")
end

local function refresh_context(context)
    if context and type(context.refresh_non_confirmed_composition) == "function" then
        pcall(function() context:refresh_non_confirmed_composition() end)
    end
end

local function cancel_stale_manager_state(context, key, key_is_zero)
    if not is_plain_press(key) then return false end
    local input = context and context.input or ""
    local pending = state().pending_delete
    if pending and pending.input ~= input then
        state().pending_delete = nil
        refresh_context(context)
        return key_is_zero
    end
    if pending and not key_is_zero then
        state().pending_delete = nil
        refresh_context(context)
    end
    local notice = state().manager_notice
    if notice and (notice.input ~= input or not key_is_zero) then
        state().manager_notice = nil
    end
    return false
end

local function selected_manager_record(context, store_file)
    if not context or type(context.get_selected_candidate) ~= "function" then return nil end
    local ok, cand = pcall(function() return context:get_selected_candidate() end)
    if not ok or not cand or cand.type ~= "candidate_order_manager" then return nil end
    local line_no = (cand.comment or ""):match("〔调频·第(%d+)行·按0撤销〕$")
    if not line_no then return nil end
    local rec = core.record_at_line(tonumber(line_no), store_file)
    if not rec then return nil end
    local expected_text = rec.target_code .. "：" .. rec.promoted .. "置顶"
    if cand.text ~= expected_text then return nil end
    return rec
end

local function handle_manager_zero(context, env)
    local input = context and context.input or ""
    if management_query(input) == nil then return kNoop end

    local pending = state().pending_delete
    if pending and pending.input == input and pending.record then
        local rec = pending.record
        local ok, removed = core.remove_record_and_dependents(
            rec,
            core.store_path(get_store_file(env))
        )
        state().pending_delete = nil
        local message
        if not ok then
            message = "撤销失败：无法写入 candidate_order.txt"
        elseif removed == 0 then
            message = "未找到该调频，文件可能已被其他设备更新"
        else
            message = "已撤销调频：" .. rec.target_code .. " / " .. rec.promoted
                .. "；共清理" .. tostring(removed) .. "条"
        end
        state().manager_notice = {
            input = input,
            message = message,
            ok = ok and removed > 0,
        }
        refresh_context(context)
        return kAccepted
    end

    local rec = selected_manager_record(context, get_store_file(env))
    if rec then
        state().pending_delete = { input = input, record = rec }
        state().manager_notice = nil
        refresh_context(context)
    end
    -- Never let 0 select or commit a helper candidate in management mode.
    return kAccepted
end

local function selected_index(context)
    local comp = context and context.composition and context.composition:back()
    if not comp then return 0, nil end
    return comp.selected_index or 0, comp
end

local function get_candidate_at(comp, index)
    if not comp then return nil end
    local ok, cand = pcall(function() return comp:get_candidate_at(index) end)
    if ok then return cand end
    return nil
end

local function get_first_candidate(comp)
    return get_candidate_at(comp, 0)
end

local function prefix_fallback_records(input, store_file)
    local out = {}
    local ok, _, new_records = pcall(core.records_for_input, input, store_file)
    if not ok or type(new_records) ~= "table" then return out end

    for _, rec in ipairs(new_records) do
        if rec.displaced and rec.new_code
            and #input < #rec.new_code
            and input ~= rec.target_code
            and rec.new_code:sub(1, #input) == input then
            out[rec.displaced] = rec
        end
    end
    return out
end

local function prefix_fallback_record(cand, fallback_records)
    return cand and cand.type == "candidate_order"
        and fallback_records and fallback_records[cand.text] or nil
end

local function is_prefix_fallback_candidate(cand, fallback_records)
    return prefix_fallback_record(cand, fallback_records) ~= nil
end

local function get_non_prefix_candidate_at_or_after(comp, start_index, fallback_records)
    for index = start_index, start_index + 9 do
        local cand = get_candidate_at(comp, index)
        if not cand then return nil, nil end
        if not is_prefix_fallback_candidate(cand, fallback_records) then
            return cand, index
        end
    end
    return nil, nil
end

-- ══ 「码 → 该码首位词」缓存（被挤者的唯一可靠来源） ═══════════════════
-- 按 0 时，被挤者应该是**短码 short_code 处原本的首位词**
-- （例：输入 ceeli → 把「侧说」前移到 ceel，被挤掉的是 ceel 上原本的「策说」）。
-- 但按 0 那一刻候选列表是 ceeli 的，那个词**根本不在里面**
-- （实测：ceeli 只有「侧说」；策说挂在 ceel / cizu 词库），
-- 而 librime 没有「码 → 首选词」的反查 API（评估稿 4.2 节说的就是这件事）。
--
-- 好在 candidate_order_processor 在 engine.processors 里排在 **speller 之前**
-- （build/xmjd6.schema.yaml 第 87 行 vs 第 100 行），所以每次**按下**字母键时
-- 它看到的还是**加键之前**的 input 与候选列表：
--     按下 ceeli 的第 5 个键 i → 此刻 input = "ceel"、候选 = ceel 的候选
--     紧接着按 0              → input = "ceeli"，short_code = "ceel"
-- 于是把「input → 该码首位词」逐键记进一张小表，按 0 时直接查 short_code。
--
-- ★★ 只在**按下**（非 release）时记录 —— 这是 2026-09-27 真机实测踩出来的坑：
--   release 事件里 context.input **已经**含上新字母了（speller 已处理过 press），
--   而 is_hotkey() 对 release 一律返回 false，于是 release 也会走
--   remember_menu 分支，把「松 i」当成一次普通按键：
--       repr=i          rel=false input="ceel"  → 记下 ceel/策说     ← 有用
--       repr=Release+i  rel=true  input="ceeli" → 覆盖成 ceeli/侧说  ← 污染
--   结果按 0 时 snap.input ≠ short_code → 永远取不到被挤者 →
--   静默退化成自指 → 只写出 4 字段（无补码）。
--   修好后还必须让冒烟测试也模拟 press+release，否则测不出来。
local menu_first_cache = {}

local function remember_menu(key, context, comp, store_file)
    -- 只认「按下」的普通按键：release 时 input 已被 speller 改过；
    -- 带 Ctrl/Alt/Super 的按键不改变编码语义（如 Ctrl+V 粘贴）。
    if not key or key:release() or key:ctrl() or key:alt() or key:super() then
        return
    end

    local input = context.input or ""
    if input == "" then
        menu_first_cache = {}   -- 新一次组码开始，整张表作废
        return
    end
    if not input:match("^[a-z]+$") then return end
    if not context:has_menu() then return end

    local first = get_non_prefix_candidate_at_or_after(
        comp, 0, prefix_fallback_records(input, store_file))
    if first and first.text and first.text ~= "" then
        menu_first_cache[input] = first.text
    end
end

-- 候选词的字数，只用来算音码位数。Weasel 内嵌 Lua 5.4，utf8 必然可用；
-- 兜底按 UTF-8 首字节计数（连续字节 0x80~0xBF 不计）。
local function text_char_len(text)
    if type(text) ~= "string" then return 0 end
    if utf8 and utf8.len then
        local n = utf8.len(text)
        if n then return n end
    end
    local n = 0
    for i = 1, #text do
        local b = text:byte(i)
        if b and (b < 0x80 or b > 0xBF) then n = n + 1 end
    end
    return n
end

-- 「编码档位前移一位」的下界：再减一位就切进音码区，不是合法档位了。
-- 键道6 码结构见 candidate_order.lua 的 phrase_full_code：
--   单字        → 1 （单字码本身是 1~6 位递进码，最短 1 位：不=b / 宾=bb / 滨=bba）
--   2 字词      → 4 （音码 4 位 + 形码 2 位）
--   3 字词      → 3 （音码 3 位 + 形码 3 位）
--   4 字词及以上 → 4 （音码 4 位 + 形码 2 位）
local function min_code_len_for(text)
    local n = text_char_len(text)
    if n <= 1 then return 1 end
    if n == 3 then return 3 end
    return 4
end

-- ══ 「候选的真实码」 ═══════════════════════════════════════════════════
-- 按 0 时 context.input 是**已输入的内容**，候选列表是上一键算好的当前菜单
-- （原理见 remember_menu 上方：processor 排在 speller 之前）。
--
-- ★ 关键：候选列表里会混着**补全候选** —— 它在 input 上就能看见，但真实码更长。
--   rime 的 enable_completion（build/xmjd6.schema.yaml:706）就是这个；
--   注释里带剩余部分：输入 ceeli 时「从上市以来」显示成「从上市以来 ~i」，
--   意思是真实码 = ceeli .. "i" = ceelii。
--   本方案自己的 candidate_order translator 照抄了这个格式，所以
--   `~剩余码` 就是本方案里「真实码比 input 长」的统一表示。
--
--   为什么必须还原真实码：0 的语义是「候选**编码**从右往左减少一位」。
--   把 input 当成码就会算错 —— 真机实测（2026-09-27 第 6 轮，日志里 `sel="从上市以来"`、
--   `cache[short]="侧说"` 那一行）：
--     输入 ceeli（此时菜单只剩补全 从上市以来 ~i）按 0
--     → 旧实现把 input 当码，落点算成 "ceel" ⇒ 等于让 ceelii 一步跳到 ceel，
--       跨了两档，写出一条毫无意义的规则；而 ceeli 仍是用户说的「空码」。
--   按真实码算 ⇒ 落点 = ceelii 少一位 = ceeli，从上市以来**就地**变成真候选，
--   再按一次 0 才会进到 ceel —— 这才是「后面有一位直接能前移」。
local function candidate_code(cand, input)
    if type(input) ~= "string" or input == "" then return input end
    local comment = cand and cand.comment
    if type(comment) == "string" and comment ~= "" then
        -- 只认开头那段纯码字符：别的 filter 会往注释后面追加内容
        -- （for_hint 追加 "〔xx〕"、cx_pinyin_hint 追加拼音），这里不跟着跑偏。
        local rest = comment:match("^~([a-z]+)")
        if rest and rest ~= "" then
            local full = input .. rest
            if #full > #input then return full end
        end
    end
    return input
end

-- ══ 「该码后面的一位」 ═════════════════════════════════════════════════
-- 某个码上没有精确候选（只剩补全候选）时，它的「后面的一位」= 排在**最前面**、
-- 并且能**正好一位**顺延上来的那个补全候选。
-- 两条路径共用它：
--   ① 按 0 前移后**级联**（被腾空的码立刻补位）—— skip_text = 刚搬走的那个词；
--   ② 非字母键的兜底顺延（见 auto_cascade）—— skip_text = nil。
--
-- 返回 (候选, 它的真实码)；返回 nil 表示**不该顺延**，理由在下面每一处 return 上。
--
-- ★★ 第 11 轮新增 fresh_data 参数：注入的「~剩余码」候选分两种，必须区别对待。
--   真机现场（用户第 11 轮，6 步循环的第 5→6 步）：
--     文件 = 策说 ceelu 侧说 ceel ceeli ／ 侧说 ceel 从上市以来 ceeli ceelii
--     此刻 ceeli 的候选 = 侧说[注入] > 从上市以来(~i)[注入] > 从山上下来(~i)[原生]
--     第 2 个是**注入**的（上一条规则 new_code 的提示）。旧逻辑「遇到注入的 ~
--     就放弃整个码」⇒ 级联不触发 ⇒ ceeli 变不回真候选（用户看到的第 6 步退化：
--     又需要空格上屏一次）。而第 2 步同样的操作却正常 —— 差别只在于那时
--     ceeli 上没有这条规则，那个 ~i 是**原生**补全。
--   但注入的 ~ 也不能一律采信：只要那条规则还在，这个码就是被规则管着的
--   （promoted 正钉在这里），顺延上去只会打架。
--   所以判据是「**提示背后的规则还在不在**」：
--     · fresh_data 里 by_new[code..rest] 仍有 displaced == 该词的记录 → 规则还在 → 放弃；
--     · 规则已经没了（本次按键把它删掉了）⇒ 这条 ~ 是**过期提示**，
--       该码已经真的空了 → 与原生补全一视同仁。
--   fresh_data == nil 时保持旧的严格行为：auto_cascade 兜底那条路不传它，
--   它自带 `data.by_target[input]` 守卫，不需要这一层。
local function rule_backs_hint(data, full_code, text)
    if not data or type(data.by_new) ~= "table" then return false end
    for _, rec in ipairs(data.by_new[full_code] or {}) do
        if rec.displaced == text then return true end
    end
    return false
end

local function next_in_line(comp, code, skip_text, fresh_data)
    -- 只看前 20 个。精确候选必然排在补全候选之前，所以扫到第一个补全就够，
    -- 这个上界只是防御性的（真机上同一个码的候选可能有几十个）。
    for index = 0, 19 do
        local cand = get_candidate_at(comp, index)
        if not cand then return nil end

        local c = cand.comment
        local rest = type(c) == "string" and c:match("^~([a-z]+)") or nil

        if cand.type == "candidate_order" then
            -- translator 自己注入的候选：
            --   置顶注入（注释为空）→ 跳过继续看；
            --   带 ~ 提示的 → 背后规则还在（或没给 fresh_data）就放弃整个码；
            --                规则已被删 ⇒ 过期提示，按原生补全处理。
            if rest then
                if not fresh_data or rule_backs_hint(fresh_data, code .. rest, cand.text) then
                    return nil
                end
                if #rest ~= 1 then return nil end
                if #code < min_code_len_for(cand.text) then return nil end
                return cand, code .. rest
            end
        elseif cand.text and cand.text ~= "" and cand.text ~= skip_text then
            -- 没有 ~剩余码 ⇒ 它是精确候选 ⇒ 该码**不是**空码，谁也轮不到顺延
            if not rest then return nil end
            -- 最前面这个补全自己就要跨档（真实码比 code 长两位以上）⇒ 不越过它去找别人
            if #rest ~= 1 then return nil end
            -- 落点必须是合法档位（与按 0 那条路共用同一个下界）
            if #code < min_code_len_for(cand.text) then return nil end
            return cand, code .. rest
        end
    end
    return nil
end

-- ══ 「空码自动顺延」（非字母键兜底） ═══════════════════════════════════
-- 用户诉求（2026-09-27 第 8 轮）：
--   「ceeli 变成空码后，从上市以来 按了 0 会变成真候选；现在需要不按 0 就直接顺延。」
-- 语义：某个码上**没有精确候选**、屏幕上只剩补全候选（注释形如 ~剩余码）时，
-- 你一旦停下组码开始用它（空格 / 数字 / 回车 / ←→ / 翻页键…），就把该码
-- 「后面的一位」**就地**落成这个码的真候选 —— 等价于「对它按一次 0」：
--     输入 ceeli（空码）→ 屏幕：从上市以来 ~i
--     顺手按空格        → 落盘 从上市以来<TAB>ceelii<TAB>从上市以来<TAB>ceeli
--                       → 从此 ceeli 上它就是**真候选**（不再带 ~i），
--                         而它在 ceelii 处的原生/补全副本被隐藏。
--
-- ★★ 第 9 轮补充（用户：「是否可以修改成不按空格，直接在修改 ceeli 后，
--    后面的 ceelii 就直接跟着变成 ceeli」）：**主路径改成了按 0 时的级联**
--    （见 processor 里 append_order 成功之后那段）。本函数退化为**兜底**：
--    只有那种「不是因为刚按 0 才变空」的空码（历史遗留 / 手动撤销过调频）才会走到这里。
--    两条路共用 next_in_line()，所以口径一致。
--
-- ★ 为什么当初不把兜底做成「一显示就落盘」：
--   processor 排在 speller 之前、**每按一键**都会跑。若一显示就写，
--   打 ceelii 的中途必然经过 ceeli → 会给 ceeli 写一条谁也没想要的规则，
--   并把它在 ceelii 的原生副本永久藏掉（第 6 轮那个「跨两档」的坑换个面貌复现）。
--   排除字母键 = 用户还在往长里组码，别动；非字母键 = 用户开始消费这个菜单了。
--
-- ★ 判据（都在 next_in_line 里）：扫过注入候选，第一位原生候选必须是
--   「正好能一位顺延」的补全候选。有精确候选 ⇒ 该码不是空码；
--   第一位补全就跨档 ⇒ 不越过它去找别人；落点非法档位 ⇒ 不做。
--   ★ 第 11 轮补充：**注入**的「~剩余码」提示要看它背后的规则还在不在
--   （fresh_data），规则已被删 ⇒ 过期提示 ⇒ 与原生补全同等对待。
--
-- ★ target_code 处已经有注入记录的码直接跳过：说明这个码已经调过频。
--   ⚠️ 这条不只是「别越堆越高」—— append_order 对**自指记录重复写入**会把它
--   当成「撤销上一次前移」而删掉（candidate_order.lua:1261 的 inverse 判定），
--   所以必须在这里拦住，不能让它走到写盘那一步。
--
-- ★ 不理会高亮：顺延的是「该码第一位」，也就是唯一那个「后面的一位」。
--   （用户既往要求「按 0 一律以当前高亮为准」，那是 0 的语义；顺延没有选择余地。）
--
-- ★ 不调 refresh_context：它会重置 highlighted index，紧接着按的空格 / 数字
--   就会上屏错词。落盘的可见效果延后到下一次翻译，不影响本次按键。

-- 会让 input 变长的键：单个字母（含 Shift 后的大写）、' 连打分隔符、` 反查。
local function is_code_extension_key(key)
    local repr = key:repr() or ""
    if #repr ~= 1 then return false end
    return repr:match("[%a'`]") ~= nil
end

local function auto_cascade_enabled(env)
    -- candidate_order/auto_cascade 默认**开**，值写 "enable"；写 "disable" 关掉。
    -- ★ 为什么不用 true/false 或 on/off：
    --   ① librime 的 get_bool 对「键不存在」同样返回 false，「忘配」会被当成「关」；
    --   ② 部署器会把标量规范化（源文件里的 hotkey: "0" 到 build 里变成 hotkey: 0），
    --      数字串会被类型化；on/off 在 YAML 里也可能被解析成布尔。
    --   所以只认「明确写成关」的字符串，其余（含读不到）一律当开。
    local cfg = env and env.engine and env.engine.schema and env.engine.schema.config
    if not cfg then return true end
    local ok, raw = pcall(function() return cfg:get_string("candidate_order/auto_cascade") end)
    if ok and type(raw) == "string" then
        local v = raw:lower()
        if v == "disable" or v == "off" or v == "false" or v == "no" then return false end
    end
    return true
end

local function auto_cascade(key, context, comp, store_file)
    if not is_plain_press(key) then return end
    if is_code_extension_key(key) then return end

    local input = context.input or ""
    if input == "" or not input:match("^[a-z]+$") then return end
    if not context:has_menu() then return end

    local ok_load, data = pcall(core.load, store_file)
    if not ok_load or type(data) ~= "table" or type(data.by_target) ~= "table" then return end
    -- 该码已经有过调频（translator 会在 target_code 处注入置顶词）→ 不再顺延。
    -- ★ 这条还不只是「别越堆越高」：append_order 对**自指记录重复写入**会把它
    --   当成「撤销上一次前移」而删掉（见 candidate_order.lua:1261 的 inverse 判定），
    --   所以「该码已调过频」必须在这里就拦住，绝不能让它走到写盘那一步。
    if data.by_target[input] then return end

    local cand, cand_code = next_in_line(comp, input, nil)
    if not cand then return end

    local ok = core.append_order({
        promoted = cand.text,
        old_code = cand_code,       -- 隐藏它在真实码处的原生/补全副本
        displaced = cand.text,      -- 自指 → 不补码，写成 4 字段
        target_code = input,        -- 就地落成本码的真候选
    }, core.store_path(store_file))

    if ok then
        menu_first_cache = {}   -- 各码首位词可能已经变了
    end
end

local function processor(key, env)
    local engine = env and env.engine
    local context = engine and engine.context
    if not context then return kNoop end

    local key_is_zero = is_plain_zero(key)
    if cancel_stale_manager_state(context, key, key_is_zero) then
        return kAccepted
    end
    if key_is_zero and management_query(context.input or "") ~= nil then
        return handle_manager_zero(context, env)
    end

    if not core.is_enabled(env) then return kNoop end

    local store_file = get_store_file(env)
    local _, comp = selected_index(context)

    if not is_hotkey(key, get_hotkey(env)) then
        -- 非热键：逐键记下「input → 该码首位词」，供按 0 时查 short_code。
        -- 只在「按下」时记（release 的 input 已被 speller 改过，见上方注释）。
        remember_menu(key, context, comp, store_file)
        -- 空码自动顺延：非字母键 = 用户开始消费这个菜单了。
        -- ★ 必须排在 remember_menu 之后：写盘会清 menu_first_cache，
        --   顺序反了就会被它紧接着填回旧值。
        if auto_cascade_enabled(env) then
            auto_cascade(key, context, comp, store_file)
        end
        return kNoop
    end

    if not context or not context:has_menu() then return kNoop end

    local target_code = context.input or ""
    if not target_code:match("^[a-z]+$") then return kNoop end

    local selected = context:get_selected_candidate()
    local visual_first = get_first_candidate(comp)
    local fallback_records = prefix_fallback_records(target_code, store_file)
    local first = get_non_prefix_candidate_at_or_after(comp, 0, fallback_records)
    if not first or not first.text or first.text == "" then return kNoop end

    -- When typing a generated fallback code only partially, candidate_order may
    -- yield a synthetic completion such as 缘由(~i). It is only a hint for the
    -- displaced word, not the real "first candidate". If the user highlights
    -- the real exact candidate below it (源由 at ytyda in the regression case),
    -- just clear the stale menu instead of appending an extra wrong rule.
    if visual_first and is_prefix_fallback_candidate(visual_first, fallback_records)
        and selected and selected.text == first.text then
        context:clear()
        return kAccepted
    end

    -- But if the user explicitly highlights that synthetic completion itself,
    -- promote it to the current prefix and move the real first candidate to the
    -- old fallback code. Example:
    --   before: ytyda = 源由, 缘由 completes to ytydai
    --   after : ytyda = 缘由, 源由 moves to ytydai
    local selected_prefix_rec = prefix_fallback_record(selected, fallback_records)
    if selected_prefix_rec then
        local ok = core.promote_prefix_fallback(
            selected_prefix_rec,
            target_code,
            first.text,
            core.store_path(store_file)
        )
        if ok then context:clear() end
        return kAccepted
    end

    -- ── 目标候选 = **屏幕上高亮的那一个** ───────────────────────────────
    -- 2026-09-27 用户反馈：旧行为在「高亮还在首位」时会自动改提次选
    -- （原注释写的 Mobile-friendly behavior），于是出现
    -- 「我要前移当前候选，结果却是次选被前移了」。
    -- 现在一律以当前高亮候选为准 —— 想动谁就先用 ←/→（或翻页键）把高亮
    -- 移到那个候选上，再按 0。
    if not selected or not selected.text or selected.text == "" then
        return kAccepted
    end

    local promoted = selected.text
    -- ★ 候选的真实码 = context.input（普通候选） 或 input .. ~剩余码（补全候选）。
    --   0 的语义是「从**编码**右往左少一位」，所以一切都基于真实码算。
    local promoted_code = candidate_code(selected, target_code)
    -- 落点码 = 真实码少一位 —— 后面守卫会用，这里先算出来给「被挤者」查询用。
    local short_code = promoted_code:sub(1, #promoted_code - 1)

    -- ── 被挤者 = **短码(short_code)处原本的首位词** ──────────────────────
    -- 这才是补码的语义：ceeli 的「侧说」前移到 ceel，被挤掉的是 ceel 上
    -- 原本的「策说」→ 策说补一码（ceelu）+ 原码副本被隐藏。
    -- 注意查的是 **short_code**，不是 target_code：
    --   打 ceeli 时 → short_code = "ceel"，缓存里「按第 5 个键时记下的 ceel」正好命中。
    -- 三种取值，按可靠性降序：
    --   ① menu_first_cache[short_code] —— 用户逐键组码时抓到的「该码首位词」，
    --      权威值：即使它 == promoted（说明该词本来就已经在 short_code 上置顶）
    --      也照用，此时 record_needs_new_code() 判为「不需要补码」，
    --      记录自动退化成 4 字段（只做前移 + 隐藏原码副本）。
    --   ② 当前候选列表里 promoted 之外的首位 —— 缓存缺失时的兜底
    --   ③ promoted 自己 —— 自指，同样退化成 4 字段
    local cached = menu_first_cache[short_code]
    local displaced
    if cached and cached ~= "" then
        displaced = cached
    elseif promoted ~= first.text then
        displaced = first.text
    else
        displaced = promoted
    end

    -- ══ 0 的语义：「编码档位前移一位」 ══════════════════════════════════
    -- 把当前高亮候选的编码从右往左少一位，让它比原来早一个键位出现；
    -- **被挤者同时补码一位**（= 落到比 target_code 更长一档的码上）：
    --   输入 qzywv，选中第 2 候选 B → 写一条
    --     B <qzywv> A <qzyw> <A 的新码>
    --   于是 qzyw 处 B 置顶、A 被挤下去但仍以「更长码 + ~后缀」入口可见，
    --   而 A 在 qzyw 处的原生副本被隐藏。
    -- 两个取舍：
    --   ① **不传 no_auto_code** —— 要让 append_order 自动补码。这条路原本要
    --      全量扫 22.8 MB / 146 万行（实测 1.15 s，会冻结按键），
    --      2026-09-27 起改走 <用户目录>/idx_candidate_order/ 磁盘索引 → 10 ms 级；
    --      索引缺失/过期会自动退回全量扫描（慢，但结果一样）。
    --   ② old_code 传候选的**真实码**：用户按 0 时看到的候选就出现在这个码上，
    --      隐藏它才能让「编码少了一位」这件事真的生效。
    local floor_len = min_code_len_for(promoted)
    if #short_code < floor_len then
        -- 落点码已经短于合法档位（再减就切进音码区），直接静默结束（清掉菜单，不写记录）。
        -- 注意判的是**落点码**：对普通候选 short_code = input-1，与旧写法
        -- `#input <= floor_len` 完全等价；对补全候选落点码比 input 只短一位，
        -- 若还按 input 判，4 字词上的补全（如 ceel 上的「从上市以来 ~ii」，
        -- 真实码 ceelii）会被误挡 —— 它的落点 ceeli 其实是合法的 k=1 档位。
        context:clear()
        return kAccepted
    end

    local ok = core.append_order({
        promoted = promoted,
        old_code = promoted_code, -- 隐藏 promoted 在**真实码**处的原生/补全副本
        displaced = displaced,    -- 被挤者，补码由 append_order 自动算
        target_code = short_code, -- ★ 短一位
    }, core.store_path(store_file))

    if ok then
        -- 记录变了 → 各码的首位词都可能已经变了，缓存立刻作废。
        menu_first_cache = {}
        -- ══ 级联顺延（用户 2026-09-27 第 9 轮） ══════════════════════════
        -- 「不按空格，直接在修改 ceeli 后，后面的 ceelii 就直接跟着变成 ceeli」
        -- 这一次 0 刚把 promoted 从 **promoted_code** 上搬走（搬去 short_code），
        -- 那一码可能因此变成空码 —— 是空码就把它的「后面的一位」也一起顶上来。
        -- 于是一次按键完成整条链（真机实测的那条）：
        --     ceel  = 侧说          （本次前移的落点）
        --     ceeli = 从上市以来     （级联补位，来源是 ceelii 的补全候选）
        --     ceelu = 策说          （被挤者按键盘规则补码）
        --     ceelii 处 从上市以来 的原生副本被隐藏
        --
        -- 三道前提，缺一不可：
        --   ① promoted_code == target_code：只有**普通候选**前移时，被腾空的那一码
        --      才等于 context.input，手上这份候选列表才对得上；补全候选前移腾空的是
        --      它更长的真实码，列表不在手里 → 跳过。
        --   ② data.by_target[promoted_code] 为空：那一码还没被调过频。
        --      ★ 这条同时挡住 append_order 的 inverse 判定 —— 自指记录（promoted ==
        --        displaced）重复写入时会被它当成「撤销上一次前移」而**删掉**，
        --        所以绝不能让级联去重写一条已存在的规则。
        --   ③ next_in_line 里再挡：扫过刚搬走的那个词之后，第一位必须是
        --      「正好能一位顺延」的补全候选（有别的精确候选 / 跨档 / 落点非法 → 都不做）。
        --   ④ 第 11 轮补充：把**刚重新读出来的 cdata** 交给 next_in_line。
        --      上面这次 0 可能刚把「占着 promoted_code 的那条规则」删掉了
        --      （比如侧说从 ceeli 挪回 ceel 时，规则「…从上市以来 ceeli ceelii」
        --        因「同一个词只允许钉在一个码上」被删），于是 ceeli 上原本那条
        --      **注入**的 ~i 提示就成了过期提示 —— 不告诉 next_in_line 就会
        --      被它当成「这个码被规则管着」而放弃级联（用户第 11 轮的第 6 步退化）。
        if promoted_code == target_code then
            local ok_c, cdata = pcall(core.load, store_file)
            if ok_c and type(cdata) == "table" and type(cdata.by_target) == "table"
                and not cdata.by_target[promoted_code] then
                local nc, nc_old = next_in_line(comp, promoted_code, promoted, cdata)
                if nc then
                    core.append_order({
                        promoted = nc.text,
                        old_code = nc_old,        -- 隐藏它在真实码处的原生/补全副本
                        displaced = nc.text,      -- 自指 → 不补码，写成 4 字段
                        target_code = promoted_code,
                    }, core.store_path(store_file))
                    menu_first_cache = {}
                end
            end
        end
        -- Clear stale menu. Type the same code again to see the adjusted order immediately.
        context:clear()
        return kAccepted
    end

    return kAccepted
end

local function fini(env)
    -- 方案卸载时清掉管理面板的全局暂存状态（pending_delete / manager_notice）。
    -- 这里只清全局表；下次 state() 会按需重建，不会留下 nil upvalue。
    _G.__candidate_order_manager_state = nil
end

return { func = processor, fini = fini }
