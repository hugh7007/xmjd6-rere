-- single_char_first.lua
-- 同码单字优先（合并版）：把候选框里的「单字」排到「多字词」前面。
-- schema 引用：lua_filter@*xmjd6/single_char_first
--
-- 设计要点（性能优先）：
--   1. 稳定分区：不改变任何候选的 quality，只调整输出次序。单字上浮、多字词下沉，
--      各自内部保持原有相对次序（含表内原序、调频结果、完整度排序）。
--   2. 短路透传：候选数不够、或开关关闭时，直接原样 yield，零额外开销。
--   3. 纯内存单次遍历，不读词库、不查反查、无磁盘 IO。
--
-- 【重要】开关的判定顺序（这是本文件的关键逻辑）
--   运行时 toggle（Switcher 选项）是唯一的运行时真源。
--   schema 里的 `enabled` 只作为「选项不存在 / 不可用」时的兜底默认值。
--
--   ⚠️ 关键：`context:get_option()` 对「未注册的选项」返回 nil（且不抛错），
--      而对「已注册但被关闭」的选项返回 false。两者语义完全不同：
--        nil   → 选项不存在 → 回落到 enabled
--        false → 用户关闭   → 必须真的关闭
--      早期版本把 nil 与 false 混为一谈（或反之漏判），导致开关关不掉。
--
-- 配置（xmjd6.schema.yaml 的 single_char_first 段）：
--   enabled: true          总开关（兜底默认值；运行时以 switches 选项为准）
--   option_name: single_char_first   Switcher 选项名
--   min_candidates: 4      候选数达到该值才启用重排
--   keep_phrases: 1        置顶保留前 N 个（原序）不参与重排
--   max_scan: 0            最多扫描多少候选；0 = 不限

local M = {}

local function get_bool(config, key, default)
    if not config then return default end
    local ok, value = pcall(function() return config:get_bool(key) end)
    if ok and value ~= nil then return value end
    return default
end

local function get_int(config, key, default)
    if not config then return default end
    local ok, value = pcall(function() return config:get_int(key) end)
    if ok and value ~= nil then return value end
    return default
end

local function get_string(config, key, default)
    if not config then return default end
    local ok, value = pcall(function() return config:get_string(key) end)
    if ok and value ~= nil and value ~= "" then return value end
    return default
end

-- 候选项是否为「中文字」意义上的单字：全文恰好一个 Unicode 码点，且首字节 >= 0xC0
-- （即非 ASCII）。这样纯字母/数字/标点（如 x、1、?）不会被当成单字浮上来。
-- utf8.len 在 librime 内是 C 实现，成本极低；且只在候选数够多时才被调用。
local function is_single_char(text)
    if type(text) ~= "string" or text == "" then return false end
    local first = text:byte(1)
    if not first then return false end
    -- 非 ASCII 才可能算「中文字」；ASCII（含字母数字标点）直接排除
    if first < 0xC0 then return false end

    if utf8 and utf8.len then
        local ok, n = pcall(utf8.len, text)
        if ok and n then return n == 1 end
    end
    -- 退化路径：utf8 不可用时按前导字节推断码点长度
    local len = 2
    if first >= 0xF0 then len = 4
    elseif first >= 0xE0 then len = 3 end
    return #text == len
end

local function init(env)
    local config = env.engine.schema.config
    env.scf_enabled = get_bool(config, "single_char_first/enabled", true)
    env.scf_min = get_int(config, "single_char_first/min_candidates", 4)
    env.scf_keep = get_int(config, "single_char_first/keep_phrases", 1)
    env.scf_max_scan = get_int(config, "single_char_first/max_scan", 0)
    env.scf_option = get_string(config, "single_char_first/option_name", "single_char_first")
end

local function fini(env)
    env.scf_enabled = nil
    env.scf_min = nil
    env.scf_keep = nil
    env.scf_max_scan = nil
    env.scf_option = nil
end

local function pass_through(input)
    for cand in input:iter() do
        yield(cand)
    end
end

-- 运行时是否启用。
-- get_option 的返回值语义（已在 lupa 下实测确认）：
--   选项存在且开 → true / 1
--   选项存在且关 → false / 0        ← 必须能识别为「关」
--   选项不存在   → nil（且 pcall 返回 ok=true，librime 不抛错）
--   抛错         → ok=false（罕见，如 context 已失效）
-- 因此「nil」只能解读为「选项不存在」，绝不能解读为「关闭」。
local function runtime_on(env)
    local context = env.engine.context
    if env.scf_option and context and context.get_option then
        local ok, on = pcall(function() return context:get_option(env.scf_option) end)
        if ok and on ~= nil then
            -- 选项确实存在：以它为准
            if on == false or on == 0 or on == "false" or on == "0" or on == "" then
                return false
            end
            return true
        end
    end
    -- 选项不存在或不可用：回落到 schema 里的 enabled
    return env.scf_enabled ~= false
end

local function filter(input, env)
    if not runtime_on(env) then
        pass_through(input)
        return
    end

    -- 收集候选。未达到阈值就直接原样输出，不做任何额外工作。
    local all = {}
    local count = 0
    local max_scan = env.scf_max_scan or 0
    for cand in input:iter() do
        count = count + 1
        all[count] = cand
        if max_scan > 0 and count >= max_scan then break end
    end

    local min_cand = env.scf_min or 4
    if count < min_cand then
        for i = 1, count do yield(all[i]) end
        return
    end

    local keep = env.scf_keep or 0
    if keep < 0 then keep = 0 end
    if keep > count then keep = count end

    -- 置顶保留区：原序输出
    for i = 1, keep do
        yield(all[i])
    end

    -- 稳定分区：先全部单字，再全部非单字；各自保持原相对次序。
    for i = keep + 1, count do
        local cand = all[i]
        if is_single_char(cand.text) then
            yield(cand)
        end
    end
    for i = keep + 1, count do
        local cand = all[i]
        if not is_single_char(cand.text) then
            yield(cand)
        end
    end
end

M.init = init
M.func = filter
M.fini = fini
M.is_single_char = is_single_char
M.runtime_on = runtime_on

return M
