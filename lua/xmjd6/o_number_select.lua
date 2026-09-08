-- o_number_select.lua  (v4)
-- o 模式（五笔画反查）用数字键 1~9 选中候选并直接上屏。
--
-- 根因链（为什么 o 模式数字无效而普通模式有效）：
--   1. recognizer/patterns/xmjd6gbk 原为 "^o[a-z0-9]+$" —— [0-9] 让 recognizer
--      把数字键吞进编码串（"ovi" + "2" → "ovi2"），数字永远到不了 selector。
--      词典正文 0 条含数字的码，[0-9] 是死配置 → 已从 pattern 中移除。
--   2. 即使落到 selector，也只按 page_size 选 1~5；本处理器提供第一页
--      1~9 直选（6~9 可直接选中未显示的候选），并挂在 recognizer 之前。
--
-- 挂载位置（xmjd6.schema.yaml / engine/processors）：
--   紧贴 ascii_composer 之后 —— 早于 recognizer / speller / selector。
--
-- API 选型（全部有本方案先例，勿用频次为 0 的方法）：
--   ctx.composition:back()            -- candidate_order_processor.lua L153
--   seg.selected_index                -- 同上 L155（属性）
--   seg:get_candidate_at(index)       -- 同上 L160
--   engine:commit_text(text)          -- direct_ascii.lua
--   ctx:clear()                       -- 多处
--
-- 配置：
--   o_number_select:
--     prefix: "o"     tag: xmjd6gbk    page_size: 0(自动)    max_index: 9
--     debug: true     # 诊断：写 C:\Users\yao\AppData\Local\Temp\o_number_select.log

local kAccepted = 1
local kNoop = 2

local DEBUG = false
local DEBUG_PATH = "C:\\Users\\yao\\AppData\\Local\\Temp\\o_number_select.log"

local function dump(msg)
    if not DEBUG then return end
    local ok, f = pcall(io.open, DEBUG_PATH, "a")
    if ok and f then
        f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f:close()
    end
end

local function current_segment(ctx)
    local ok, seg = pcall(function() return ctx.composition:back() end)
    if ok and seg then return seg end
    local ok2, comp = pcall(function() return ctx:composition() end)
    if ok2 and comp then
        local ok3, seg2 = pcall(function() return comp:back() end)
        if ok3 and seg2 then return seg2 end
    end
    return nil
end

-- 双路径取候选：seg 直接取（有先例）；失败再试 seg.menu
local function get_candidate(seg, index)
    local ok, cand = pcall(function() return seg:get_candidate_at(index) end)
    if ok and cand then return cand, "seg" end
    local okm, menu = pcall(function() return seg.menu end)
    if okm and menu then
        local ok2, cand2 = pcall(function() return menu:get_candidate_at(index) end)
        if ok2 and cand2 then return cand2, "menu" end
    end
    return nil, "none"
end

local function processor(key_event, env)
    if not key_event then return kNoop end

    local okr, rel = pcall(function() return key_event:release() end)
    if okr and rel then return kNoop end
    local okc, ctl = pcall(function() return key_event:ctrl() end)
    if okc and ctl then return kNoop end
    local oka, alt = pcall(function() return key_event:alt() end)
    if oka and alt then return kNoop end

    local ch = key_event.keycode
    if type(ch) ~= "number" then return kNoop end
    if ch < 0x31 or ch > 0x39 then return kNoop end   -- 只管 1~9

    local engine = env and env.engine
    local ctx = engine and engine.context
    if not ctx then return kNoop end

    local input = ctx.input or ""
    dump(string.format("KEY=%d input=[%s]", ch - 0x30, input))

    local prefix = env.prefix or "o"
    if input:sub(1, #prefix) ~= prefix then return kNoop end
    if #input <= #prefix then return kNoop end         -- 只敲了 o，不管

    local seg = current_segment(ctx)
    if not seg then
        dump("  -> no-composition")
        return kNoop
    end
    if type(seg.has_tag) == "function" then
        local ok2, has = pcall(function() return seg:has_tag(env.tag) end)
        if ok2 and has == false then
            dump("  -> tag-mismatch")
            return kNoop
        end
    end

    local sel = 0
    local oks, si = pcall(function() return seg.selected_index end)
    if oks and type(si) == "number" and si >= 0 then sel = si end

    local page_size = env.page_size
    local page_start = math.floor(sel / page_size) * page_size
    local offset = ch - 0x31                           -- 0-based

    local target
    if page_start == 0 then
        -- 还在第一页：1~9 直接对应第 1~9 个候选
        if offset >= env.max_index then return kNoop end
        target = offset
    else
        -- 已翻页：按当页相对位置
        if offset >= page_size then return kNoop end
        target = page_start + offset
    end

    local cand, path = get_candidate(seg, target)
    local text = (cand and type(cand.text) == "string") and cand.text or nil

    dump(string.format("  -> sel=%d page_start=%d target=%d path=%s cand=[%s]",
        sel, page_start, target, path, text or "nil"))

    if not text or text == "" then return kNoop end    -- 越界：该页没这么多候选

    engine:commit_text(text)
    ctx:clear()
    dump("  -> COMMIT [" .. text .. "]")
    return kAccepted
end

local function init(env)
    local config = env.engine.schema.config

    env.prefix = "o"
    env.tag = "xmjd6gbk"
    env.page_size = 5
    env.max_index = 9

    local ok1, v = pcall(function() return config:get_string("o_number_select/prefix") end)
    if ok1 and type(v) == "string" and v ~= "" then env.prefix = v end

    local ok2, t = pcall(function() return config:get_string("o_number_select/tag") end)
    if ok2 and type(t) == "string" and t ~= "" then env.tag = t end

    local ok3, ps = pcall(function() return config:get_int("o_number_select/page_size") end)
    if ok3 and type(ps) == "number" and ps > 0 then
        env.page_size = ps
    else
        local ok4, mps = pcall(function() return config:get_int("menu/page_size") end)
        if ok4 and type(mps) == "number" and mps > 0 then env.page_size = mps end
    end

    local ok5, mi = pcall(function() return config:get_int("o_number_select/max_index") end)
    if ok5 and type(mi) == "number" and mi >= 1 and mi <= 9 then env.max_index = mi end

    local okd, dbg = pcall(function() return config:get_bool("o_number_select/debug") end)
    DEBUG = (okd and dbg == true)

    -- 无条件打 INIT（判断模块是否真的被加载），带版本标记
    local okf, f = pcall(io.open, DEBUG_PATH, "a")
    if okf and f then
        f:write(os.date("%H:%M:%S") .. " INIT v4 debug=" .. tostring(DEBUG)
            .. " prefix=" .. tostring(env.prefix)
            .. " tag=" .. tostring(env.tag)
            .. " page_size=" .. tostring(env.page_size)
            .. " max_index=" .. tostring(env.max_index) .. "\n")
        f:close()
    end
end

return { init = init, func = processor }
