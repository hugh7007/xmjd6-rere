-- candidate_order_core.lua
-- Runtime candidate-order overrides for xmjd6.
-- Store format per line:
--   promoted_text<TAB>promoted_old_code<TAB>displaced_text<TAB>target_code
-- Optional fifth field stores displaced_new_code, generated when pressing hotkey.

local M = {}

M.default_filename = "candidate_order.txt"
M.dynamic_phrase_filename = "dynamic_phrases.txt"
M.occupied_dict_files = {
    "xmjd6.buchong.dict.yaml",
    "xmjd6.candidate_order.dict.yaml",
    "xmjd6.chaojizici.dict.yaml",
    "xmjd6.cizu.dict.yaml",
    "xmjd6.danzi.dict.yaml",
    "xmjd6.fjcy.dict.yaml",
    "xmjd6.fuhao.dict.yaml",
    "xmjd6.lianjie.dict.yaml",
    "xmjd6.same_code_short_first.dict.yaml",
    "xmjd6.user.dict.yaml",
    "xmjd6.wxw.dict.yaml",
    "xmjd6.wxwdanzi.dict.yaml",
    "xmjd6.yingwen.dict.yaml",
    "xmjd6.zidingyi.dict.yaml",
    -- xmjd6.extended imports xkjd6.liangzi; two-character words there can
    -- occupy fallback codes such as pklzo(疲痨).
    "xkjd6.liangzi.dict.yaml",
}

local cache = {
    order_path = nil,
    order_fingerprint = nil,
    data = nil,
}

-- ════════════════════════════════════════════════════════════════
-- 磁盘索引状态（由 scripts/build_candidate_order_index.py 生成）。
-- 声明在这里，是为了让下面的 clear_cache() 能把它标脏 ——
-- 每次 append_order 落盘后都会 clear_cache()，于是顺带重校验一次索引新鲜度。
-- ════════════════════════════════════════════════════════════════
local idx_state = {
    checked = false,        -- 是否已按 base_dir 校验过
    dir = nil,
    ok = false,
    reason = "unchecked",   -- ok / no-meta / stale:<文件名> / missing:<文件名> / ok-cached
    stats = { queries = 0, indexed = 0, fallback = 0, bucket_ms = 0 },
}

local function clear_cache()
    cache.order_path = nil
    cache.order_fingerprint = nil
    cache.data = nil
    idx_state.checked = false
end

do
    local ok, mem_cleaner = pcall(require, "xmjd6.mem_cleaner")
    if ok and mem_cleaner and mem_cleaner.register then
        mem_cleaner.register(clear_cache)
    end
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function path_separator()
    local cfg = package.config or "/"
    return cfg:sub(1, 1) == "\\" and "\\" or "/"
end

local function join_path(dir, name)
    if not dir or dir == "" then return name end
    local sep = path_separator()
    if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
        return dir .. name
    end
    return dir .. sep .. name
end

function M.user_data_dir()
    if rime_api and rime_api.get_user_data_dir then
        local ok, dir = pcall(rime_api.get_user_data_dir)
        if ok and dir and dir ~= "" then return dir end
    end
    return "."
end

function M.store_path(filename)
    return join_path(M.user_data_dir(), filename or M.default_filename)
end

function M.is_enabled(env)
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        local ok, value = pcall(function()
            return env.engine.schema.config:get_bool("candidate_order/enabled")
        end)
        if ok and value == false then return false end
    end
    if env and env.engine and env.engine.context and env.engine.context.get_option then
        local ok, value = pcall(function()
            return env.engine.context:get_option("candidate_order_enabled")
        end)
        if ok and value == false then return false end
    end
    return true
end

-- 规则文件的「指纹」，用来判断 M.load 的缓存是否还有效。
--
-- ★★ 必须带上**内容**，不能只比大小（2026-09-27 真机实测的根因）：
--   本机 C:\Program Files\Rime\weasel-0.17.4\ 下**没有 lfs**，旧实现于是退化成
--   「只比文件大小」。而 candidate_order.txt 里那一对记录互相重写时大小不变：
--       R1 = 侧说\tceeli\t策说\tceel\tceelu      （32 字节）
--       R2 = 策说\tceelu\t侧说\tceel\tceeli      （32 字节）
--   ⇒ 大小判等通过 → M.load 认为缓存有效 → 返回**旧数据** → 用户看到
--     「按 0 没有任何反应」（其实 append_order 已经写成功了）。
--
-- ★ 这个 bug 还和「两个模块实例」叠加放大：
--   processor 用 require("xmjd6.candidate_order")，schema 用
--   lua_*@*xmjd6/candidate_order —— Lua 的 package.loaded 对「点号」与「斜杠」
--   是两个 key，于是 processor 那份 write 之后调用的 clear_cache() **清不到**
--   引擎（translator/filter）那份的缓存。既然跨实例清不掉，就必须让指纹自己
--   发现内容变了：这是唯一不依赖「谁能清到谁」的修法。
-- lfs 只探测一次：本机 weasel 目录下**没有** lfs，而 require 失败不会被缓存，
-- 每按键一次都要重走一遍 package.path 搜索（多次失败的 fopen）。指纹是每次按键
-- 都要算的，所以这里把结果记住。
local lfs_probe = { done = false, mod = nil }
local function get_lfs()
    if not lfs_probe.done then
        lfs_probe.done = true
        local ok, mod = pcall(require, "lfs")
        if ok and mod then lfs_probe.mod = mod end
    end
    return lfs_probe.mod
end

local function file_fingerprint(path)
    if type(path) ~= "string" or path == "" then return "nil" end

    -- 有 lfs 就用修改时间 + 字节数，但没有也不影响正确性。
    -- 第十二轮三修：只比 mtime 是秒级精度 —— 外部工具在同一秒内覆盖文件时
    -- mtime 数值不变，指纹不变 → 继续用旧内容（症状：改了没反应、过几秒又好了）。
    -- 加上 size 后，同秒但字节数不同的覆盖（工具保存的真实场景）立刻能察觉。
    -- 遗留窗口：同秒 + 等字节仍察觉不到，是 mtime 秒级精度的物理极限。
    local lfs = get_lfs()
    if lfs and lfs.attributes then
        local ok, attr = pcall(lfs.attributes, path, "modification")
        if ok and attr then
            local size = -1
            local fs = io.open(path, "rb")
            if fs then
                size = tonumber(fs:seek("end")) or -1
                fs:close()
            end
            return "m" .. tostring(attr) .. ":" .. tostring(size)
        end
    end

    local f = io.open(path, "rb")
    if not f then return "nil" end
    local size = tonumber(f:seek("end")) or 0
    f:seek("set", 0)
    -- 规则文件很小（几十行）。整文件哈希；万一被人塞成大文件就只取首尾各 8 KB，
    -- 但 size 仍然参与指纹，避免「改了中间且总长不变」被漏掉太多。
    local sample
    if size <= 131072 then
        sample = f:read(size) or ""
    else
        local head = f:read(8192) or ""
        f:seek("set", size - 8192)
        sample = head .. "\0" .. (f:read(8192) or "")
    end
    f:close()

    -- djb2：够快、够散，且只用整数乘加，不依赖任何外部库。
    local hash = 5381
    for i = 1, #sample do
        hash = (hash * 33 + sample:byte(i)) % 4294967296
    end
    return string.format("c%d.%d", size, hash)
end

local function split_tab(line)
    local out = {}
    for part in (line .. "\t"):gmatch("(.-)\t") do
        out[#out + 1] = trim(part)
    end
    return out
end

local function split_space(line)
    local out = {}
    for part in line:gmatch("%S+") do
        out[#out + 1] = trim(part)
    end
    return out
end

local function split_chars(s)
    local chars = {}
    if type(s) ~= "string" then return chars end
    if utf8 and utf8.codes then
        for _, code in utf8.codes(s) do
            chars[#chars + 1] = utf8.char(code)
        end
    else
        -- Fallback: byte split; only for non-CJK runtimes without utf8 library.
        for i = 1, #s do chars[#chars + 1] = s:sub(i, i) end
    end
    return chars
end

local function text_len(s)
    if utf8 and utf8.len then
        local n = utf8.len(s)
        if n then return n end
    end
    return #split_chars(s)
end

local function is_code(s)
    return type(s) == "string" and s:match("^[a-z]+$") ~= nil
end

local function pair_key(text, code)
    return tostring(text or "") .. "\0" .. tostring(code or "")
end

function M.parse_line(line, line_no)
    if type(line) ~= "string" then return nil end
    line = line:gsub("\r$", "")
    local body = line:gsub("%s+#.*$", "")
    body = trim(body)
    if body == "" or body:sub(1, 1) == "#" then return nil end

    local parts = split_tab(body)
    if #parts < 4 then parts = split_space(body) end
    if #parts < 4 then
        return nil, "第 " .. tostring(line_no) .. " 行格式应为：提到前面的词<TAB>原码<TAB>被挤下来的词<TAB>目标码"
    end

    local rec = {
        promoted = parts[1],
        old_code = parts[2]:lower(),
        displaced = parts[3],
        target_code = parts[4]:lower(),
        line_no = line_no,
    }
    local new_code = parts[5] and parts[5]:lower() or ""
    if rec.promoted == "" or rec.displaced == "" or not is_code(rec.old_code) or not is_code(rec.target_code) then
        return nil, "第 " .. tostring(line_no) .. " 行存在空字段或非法编码"
    end
    rec.same_code = rec.old_code == rec.target_code
    if new_code ~= "" then
        if not is_code(new_code) then
            return nil, "第 " .. tostring(line_no) .. " 行补码非法"
        end
        rec.new_code = new_code
    end
    return rec
end

local function add_char_code(map, ch, code, wanted)
    if not ch or ch == "" or not is_code(code) then return end
    if text_len(ch) ~= 1 then return end
    if wanted and not wanted[ch] then return end
    -- Ignore reverse-lookup o-prefixed synthetic codes; prefer normal xmjd6 codes.
    if code:sub(1, 1) == "o" then return end
    local list = map[ch]
    if not list then
        list = {}
        map[ch] = list
    end
    for _, old in ipairs(list) do
        if old == code then return end
    end
    list[#list + 1] = code
end

local function load_char_codes_uncached(base_dir, wanted)
    local map = {}
    if wanted then
        local has_wanted = false
        for _ in pairs(wanted) do
            has_wanted = true
            break
        end
        if not has_wanted then return map end
    end
    for _, name in ipairs({ "xmjd6.cx.dict.yaml", "xmjd6.danzi.dict.yaml" }) do
        local path = join_path(base_dir, name)
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                if line ~= "" and line:sub(1, 1) ~= "#" and line:find("\t", 1, true) then
                    local text, rest = line:match("^([^\t]+)\t([^%s〔#]+)")
                    add_char_code(map, trim(text), trim(rest or ""), wanted)
                end
            end
            f:close()
        end
    end

    for _, list in pairs(map) do
        table.sort(list, function(a, b)
            if #a ~= #b then return #a > #b end
            return a < b
        end)
    end
    return map
end

local function choose_char_code(char_codes, ch, prefix)
    local list = char_codes[ch]
    if not list or #list == 0 then return nil end
    if prefix and prefix ~= "" then
        for _, code in ipairs(list) do
            if code:sub(1, #prefix) == prefix then return code end
        end
    end
    return list[1]
end

local function third(code)
    if type(code) ~= "string" then return "" end
    return code:sub(3, 3)
end

function M.phrase_full_code(text, target_code, char_codes)
    local chars = split_chars(text)
    local n = #chars
    if n == 0 then return nil end

    local codes = {}
    if n == 2 and target_code and #target_code >= 4 then
        codes[1] = choose_char_code(char_codes, chars[1], target_code:sub(1, 2))
        codes[2] = choose_char_code(char_codes, chars[2], target_code:sub(3, 4))
    else
        for i, ch in ipairs(chars) do
            codes[i] = choose_char_code(char_codes, ch)
        end
    end

    for i = 1, n do
        if not codes[i] then return nil end
    end

    if n == 1 then
        return codes[1]
    elseif n == 2 then
        return codes[1]:sub(1, 2) .. codes[2]:sub(1, 2) .. third(codes[1]) .. third(codes[2])
    elseif n == 3 then
        return codes[1]:sub(1, 1) .. codes[2]:sub(1, 1) .. codes[3]:sub(1, 1)
            .. third(codes[1]) .. third(codes[2]) .. third(codes[3])
    else
        return codes[1]:sub(1, 1) .. codes[2]:sub(1, 1) .. codes[3]:sub(1, 1) .. codes[n]:sub(1, 1)
            .. third(codes[1]) .. third(codes[2])
    end
end

function M.candidate_new_codes(target_code, full_code)
    local out = {}
    if not full_code or full_code == "" then return out end
    if target_code and target_code ~= "" and full_code:sub(1, #target_code) == target_code
        and #full_code > #target_code then
        for i = #target_code + 1, #full_code do
            out[#out + 1] = full_code:sub(1, i)
        end
    else
        out[#out + 1] = full_code
    end
    return out
end

function M.code_available(occupied, code, allowed_texts)
    if not occupied or not code or code == "" then return true end
    local occupants = occupied[code]
    if not occupants then return true end
    for text, present in pairs(occupants) do
        if present and not (allowed_texts and allowed_texts[text]) then
            return false
        end
    end
    return true
end

function M.choose_candidate_code(candidates, occupied, allowed_texts)
    if not candidates or #candidates == 0 then return nil end
    for _, code in ipairs(candidates) do
        if M.code_available(occupied, code, allowed_texts) then
            return code
        end
    end
    return candidates[#candidates]
end

function M.next_code(text, target_code, char_codes, occupied, allowed_texts)
    local full = M.phrase_full_code(text, target_code, char_codes)
    if not full or full == "" then return nil, nil end

    local candidates = M.candidate_new_codes(target_code, full)
    return M.choose_candidate_code(candidates, occupied, allowed_texts), full
end

local function add_occupied(occupied, text, code, exclude_pairs)
    if not text or text == "" or not is_code(code) then return end
    if exclude_pairs and exclude_pairs[pair_key(text, code)] then return end
    local list = occupied[code]
    if not list then
        list = {}
        occupied[code] = list
    end
    list[text] = true
end

local function normalize_target_codes(candidate_codes)
    if not candidate_codes then return nil end
    local out = {}
    local has_any = false
    for key, value in pairs(candidate_codes) do
        local code = nil
        if type(key) == "number" then
            code = value
        elseif value then
            code = key
        end
        if is_code(code) then
            out[code] = true
            has_any = true
        end
    end
    if not has_any then return nil end
    return out
end

local function load_occupied_from_table(path, occupied, exclude_pairs, target_codes)
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
        if line ~= "" and line:sub(1, 1) ~= "#" and line:find("\t", 1, true) then
            local should_parse = target_codes == nil
            if target_codes then
                for code in pairs(target_codes) do
                    if line:find("\t" .. code, 1, true) then
                        should_parse = true
                        break
                    end
                end
            end
            if should_parse then
                local text, code = line:match("^([^\t]+)\t([^%s〔#]+)")
                code = trim(code or "")
                if (not target_codes) or target_codes[code] then
                    add_occupied(occupied, trim(text or ""), code, exclude_pairs)
                end
            end
        end
    end
    f:close()
end

local function merge_occupied_map(into, extra)
    for code, texts in pairs(extra or {}) do
        if not into[code] then into[code] = {} end
        for text, present in pairs(texts or {}) do
            if present then into[code][text] = true end
        end
    end
end

local function load_dynamic_occupied(base_dir, target_codes, exclude_pairs)
    local ok, dynamic_mod = pcall(require, "xmjd6.dynamic_phrase")
    local dynamic_core = ok and dynamic_mod and dynamic_mod.core or nil
    if ok and dynamic_core and dynamic_core.load_occupied_for_codes then
        return dynamic_core.load_occupied_for_codes(
            join_path(base_dir, M.dynamic_phrase_filename),
            target_codes,
            exclude_pairs
        )
    end

    local occupied = {}
    load_occupied_from_table(
        join_path(base_dir, M.dynamic_phrase_filename),
        occupied,
        exclude_pairs,
        target_codes
    )
    return occupied
end

-- ════════════════════════════════════════════════════════════════
-- 磁盘索引层（2026-09-27）
--   「0 = 编码档位前移一位」要替被挤者补码，就必须走 append_order 的自动补码分支。
--   该分支的两次全量扫描实测 127 ms + 1064 ms ≈ 1.15 s（真实词库，22.8 MB / 146 万行），
--   按键会冻结。这里把两次扫描换成「预编译索引 + 按桶读」。
--   索引由 scripts/build_candidate_order_index.py 生成到 <base_dir>/idx_candidate_order/。
--   ⚠️ 索引缺失或过期时**自动退回全量扫描**：慢，但结果永远是对的。
-- ════════════════════════════════════════════════════════════════
M.index_dirname = "idx_candidate_order"

local function file_size_or_minus1(path)
    local f = io.open(path, "rb")
    if not f then return -1 end
    local size = f:seek("end") or 0
    f:close()
    return size
end

local function idx_root(base_dir)
    return join_path(base_dir, M.index_dirname)
end

-- 有效性：meta.txt 记着每个源词库的 size，逐个比对。
-- 用 size 而不是 mtime：能覆盖"词库被改"，且不依赖 lfs 是否存在。
-- 新增/删除词库文件也覆盖得到（meta 里对缺失文件记 -1）。
local function index_valid(base_dir)
    if idx_state.checked and idx_state.dir == base_dir then return idx_state.ok end
    idx_state.checked, idx_state.dir, idx_state.ok = true, base_dir, false
    idx_state.reason = "no-meta"

    local f = io.open(join_path(idx_root(base_dir), "meta.txt"), "r")
    if not f then return false end
    local is_ours, checked, mismatch = false, 0, nil
    for line in f:lines() do
        if not is_ours and line:find("candidate_order index v", 1, true) then
            is_ours = true
        end
        local name, size = line:match("^([^\t]+)\t(%-?%d+)\t")
        if name and size then
            checked = checked + 1
            if file_size_or_minus1(join_path(base_dir, name)) ~= tonumber(size) then
                mismatch = name
                break
            end
        end
    end
    f:close()

    if not is_ours or checked == 0 then return false end
    if mismatch then
        idx_state.reason = "stale:" .. mismatch
        return false
    end
    idx_state.ok, idx_state.reason = true, "ok"
    return true
end

-- 桶键：码的前 2 位，不足 2 位用 '_' 补（'_' 不在 [a-z] 里）。
-- 码 C 的所有行必然落在 pad2(C) 这个桶里，所以「查码 C」只读 C 自己的桶。
local function idx_pad2(code)
    local k = code:sub(1, 2)
    if #k < 2 then k = k .. string.rep("_", 2 - #k) end
    return k
end

-- 按 target_codes 精确读桶。返回 complete（false = 有桶打不开 → 调用方退回全量扫描）
local function load_occupied_from_index(base_dir, occupied, exclude_pairs, target_codes)
    local root = join_path(idx_root(base_dir), "occ")
    local done, complete = {}, true
    for code in pairs(target_codes) do
        local key = idx_pad2(code)
        if not done[key] then
            done[key] = true
            local f = io.open(join_path(root, key .. ".tsv"), "r")
            if not f then
                complete = false
            else
                for line in f:lines() do
                    -- 索引行是 code<TAB>词（与源词库的方向相反）
                    local c, text = line:match("^([^\t]+)\t([^\t]+)$")
                    if c and target_codes[c] then
                        add_occupied(occupied, text, c, exclude_pairs)
                    end
                end
                f:close()
            end
        end
    end
    return complete
end

function M.load_occupied_codes_for_candidates(base_dir, candidate_codes, exclude_pairs)
    local target_codes = normalize_target_codes(candidate_codes)
    local occupied = {}
    idx_state.stats.queries = idx_state.stats.queries + 1

    local used_index = false
    if target_codes and index_valid(base_dir) then
        used_index = load_occupied_from_index(base_dir, occupied, exclude_pairs, target_codes)
    end
    if used_index then
        idx_state.stats.indexed = idx_state.stats.indexed + 1
    else
        idx_state.stats.fallback = idx_state.stats.fallback + 1
        for _, name in ipairs(M.occupied_dict_files) do
            load_occupied_from_table(join_path(base_dir, name), occupied, exclude_pairs, target_codes)
        end
    end

    -- dynamic_phrases.txt 是用户高频改的小文件，永远实时扫，不进索引
    merge_occupied_map(occupied, load_dynamic_occupied(base_dir, target_codes, exclude_pairs))
    return occupied
end

-- 字码表：桶键 = 字的前 2 个 UTF-8 字节的 hex（451 个桶，最大 13 KB）
local function idx_char_bucket(ch)
    return string.format("%02x%02x", ch:byte(1) or 0, ch:byte(2) or 0)
end

local function load_char_codes_from_index(base_dir, wanted)
    local map = {}
    local root = join_path(idx_root(base_dir), "chars")
    local done, complete = {}, true
    for ch in pairs(wanted) do
        local key = idx_char_bucket(ch)
        if not done[key] then
            done[key] = true
            local f = io.open(join_path(root, key .. ".tsv"), "r")
            if not f then
                complete = false
            else
                for line in f:lines() do
                    local c, codes = line:match("^([^\t]+)\t([^\t]+)$")
                    if c and wanted[c] and not map[c] then
                        local list = {}
                        for code in codes:gmatch("[a-z]+") do
                            list[#list + 1] = code
                        end
                        map[c] = list
                    end
                end
                f:close()
            end
        end
    end
    -- 索引里的码在建表时已按「长度降序 → 字典序」排好，与 load_char_codes_uncached 一致
    return map, complete
end

-- 索引优先；不完整就退回全量扫描（load_char_codes_uncached 保留在上面当兜底）
local function load_char_codes(base_dir, wanted)
    if wanted and index_valid(base_dir) then
        local map, complete = load_char_codes_from_index(base_dir, wanted)
        if complete then
            idx_state.stats.indexed = idx_state.stats.indexed + 1
            return map
        end
    end
    idx_state.stats.fallback = idx_state.stats.fallback + 1
    return load_char_codes_uncached(base_dir, wanted)
end

-- 诊断用：索引是否生效、走了多少次索引 / 多少次回退
function M.index_status()
    return {
        ok = idx_state.ok,
        reason = idx_state.reason,
        checked = idx_state.checked,
        queries = idx_state.stats.queries,
        indexed = idx_state.stats.indexed,
        fallback = idx_state.stats.fallback,
    }
end

local function record_needs_new_code(rec)
    return rec and rec.promoted and rec.displaced and rec.promoted ~= rec.displaced
end

local function add_record_excludes(exclude_pairs, rec)
    if not rec then return end
    if rec.promoted and rec.old_code then
        exclude_pairs[pair_key(rec.promoted, rec.old_code)] = true
    end
    if record_needs_new_code(rec) and rec.displaced and rec.target_code then
        exclude_pairs[pair_key(rec.displaced, rec.target_code)] = true
    end
end

local function build_exclude_pairs(records, extra_rec)
    local exclude_pairs = {}
    for _, rec in ipairs(records or {}) do
        add_record_excludes(exclude_pairs, rec)
    end
    add_record_excludes(exclude_pairs, extra_rec)
    return exclude_pairs
end

local function add_order_occupancy(occupied, records, target_codes)
    for _, rec in ipairs(records or {}) do
        if (not target_codes) or target_codes[rec.target_code] then
            add_occupied(occupied, rec.promoted, rec.target_code)
        end
        if rec.new_code and rec.new_code ~= "" then
            if (not target_codes) or target_codes[rec.new_code] then
                add_occupied(occupied, rec.displaced, rec.new_code)
            end
        end
    end
end

local function append_index(index, key, rec)
    if not key or key == "" then return end
    local list = index[key]
    if not list then
        list = {}
        index[key] = list
    end
    list[#list + 1] = rec
end

local function load_orders_uncached(path)
    local records = {}
    local errors = {}
    local f = io.open(path, "r")
    if not f then
        return records, errors
    end

    local line_no = 0
    for line in f:lines() do
        line_no = line_no + 1
        local rec, err = M.parse_line(line, line_no)
        if rec then
            records[#records + 1] = rec
        elseif err then
            errors[#errors + 1] = err
        end
    end
    f:close()
    return records, errors
end

local function collect_displaced_chars(records)
    local wanted = {}
    for _, rec in ipairs(records) do
        if record_needs_new_code(rec) then
            for _, ch in ipairs(split_chars(rec.displaced)) do
                wanted[ch] = true
            end
        end
    end
    return wanted
end

local function prepare_candidate_codes(records, char_codes)
    local target_codes = {}
    local has_any = false
    for _, rec in ipairs(records or {}) do
        if record_needs_new_code(rec) and not rec.new_code then
            rec.full_code = M.phrase_full_code(rec.displaced, rec.target_code, char_codes)
            rec._candidate_new_codes = M.candidate_new_codes(rec.target_code, rec.full_code)
            for _, code in ipairs(rec._candidate_new_codes or {}) do
                target_codes[code] = true
                has_any = true
            end
        end
    end
    if not has_any then return nil end
    return target_codes
end

local function fill_new_codes(records, char_codes, data, occupied)
    for _, rec in ipairs(records) do
        if record_needs_new_code(rec) and not rec.new_code then
            local allowed = {}
            allowed[rec.promoted] = true
            allowed[rec.displaced] = true
            if not rec.full_code then
                rec.full_code = M.phrase_full_code(rec.displaced, rec.target_code, char_codes)
            end
            local candidates = rec._candidate_new_codes or M.candidate_new_codes(rec.target_code, rec.full_code)
            rec.new_code = M.choose_candidate_code(candidates, occupied, allowed)
            if data and rec.new_code and rec.new_code ~= "" then
                append_index(data.by_new, rec.new_code, rec)
            end
            add_occupied(occupied, rec.displaced, rec.new_code)
        end
    end
end

local function build_data(records, errors)
    local data = {
        records = records,
        errors = errors or {},
        by_target = {},
        by_new = {},
        by_old = {},
        by_new_prefix = {},   -- new_code 的真前缀(1..#code-1) → 记录列表，供 records_for_input O(1) 查
        code_prefixes = {},   -- 所有码的前缀集合(含完整码) → true，供 has_code_prefix O(1) 查
    }
    local function add_prefixes(set, code)
        if not code or code == "" then return end
        for i = 1, #code do
            set[code:sub(1, i)] = true
        end
    end
    for _, rec in ipairs(records) do
        append_index(data.by_target, rec.target_code, rec)
        append_index(data.by_old, rec.old_code, rec)
        if rec.new_code and rec.new_code ~= "" then
            append_index(data.by_new, rec.new_code, rec)
            for i = 1, #rec.new_code - 1 do
                append_index(data.by_new_prefix, rec.new_code:sub(1, i), rec)
            end
        end
        add_prefixes(data.code_prefixes, rec.target_code)
        add_prefixes(data.code_prefixes, rec.old_code)
        add_prefixes(data.code_prefixes, rec.new_code)
    end
    return data
end

local function copy_record(rec)
    if not rec then return nil end
    return {
        promoted = rec.promoted,
        old_code = rec.old_code,
        displaced = rec.displaced,
        target_code = rec.target_code,
        new_code = rec.new_code,
        same_code = rec.same_code,
        line_no = rec.line_no,
    }
end

local function record_matches_query(rec, query)
    if query == "" then return true end
    local needle = query:lower()
    for _, value in ipairs({
        rec.promoted,
        rec.old_code,
        rec.displaced,
        rec.target_code,
        rec.new_code,
    }) do
        if type(value) == "string" and value:lower():find(needle, 1, true) then
            return true
        end
    end
    return false
end

function M.search_records(query, filename)
    query = trim(query)
    local records = load_orders_uncached(M.store_path(filename or M.default_filename))
    local out = {}
    for _, rec in ipairs(records) do
        if record_matches_query(rec, query) then
            out[#out + 1] = copy_record(rec)
        end
    end
    return out
end

function M.record_at_line(line_no, filename)
    line_no = tonumber(line_no)
    if not line_no then return nil end
    local records = load_orders_uncached(M.store_path(filename or M.default_filename))
    for _, rec in ipairs(records) do
        if rec.line_no == line_no then return copy_record(rec) end
    end
    return nil
end

function M.load(filename)
    local base_dir = M.user_data_dir()
    local order_path = M.store_path(filename or M.default_filename)
    local order_fingerprint = file_fingerprint(order_path)

    if cache.data and cache.order_path == order_path
        and cache.order_fingerprint == order_fingerprint then
        return cache.data
    end

    local records, errors = load_orders_uncached(order_path)
    local data = build_data(records, errors)

    cache.order_path = order_path
    cache.order_fingerprint = order_fingerprint
    cache.data = data
    return data
end

function M.records_for_input(input, filename)
    local data = M.load(filename)
    local new_records = {}
    for _, rec in ipairs(data.by_new[input] or {}) do
        new_records[#new_records + 1] = rec
    end
    -- new_code 以 input 为真前缀的记录：build_data 已预建索引，无需全表扫描
    for _, rec in ipairs((data.by_new_prefix or {})[input] or {}) do
        if input ~= rec.target_code then
            new_records[#new_records + 1] = rec
        end
    end
    return data.by_target[input] or {}, new_records, data
end

function M.has_rules_for_input(data, input)
    if not data or type(input) ~= "string" or input == "" then return false end
    -- by_new 也要算：should_hide_loaded 的第三个分支会藏掉「被挤者在 new_code 处
    -- 的原生副本」。漏了它就会出现同一个词上下两遍（2026-09-27 实测：ceeli 处
    -- 侧说[注入] + 侧说[原生]）。
    return data.by_target[input] ~= nil
        or data.by_old[input] ~= nil
        or data.by_new[input] ~= nil
end

function M.has_code_prefix(prefix, filename)
    if type(prefix) ~= "string" or prefix == "" then return false end
    if not is_code(prefix) then return false end

    local data = M.load(filename)
    -- target/old/new 三码的所有前缀（含完整码）已在 build_data 预建为集合
    return (data.code_prefixes or {})[prefix] == true
end

function M.should_hide_loaded(data, input, text, cand_type)
    if cand_type == "candidate_order" then return false end
    if type(input) ~= "string" or type(text) ~= "string" then return false end
    if not data then return false end

    local target_records = data.by_target[input]
    if target_records then
        for _, rec in ipairs(target_records) do
            -- Hide the original/completion copy of the promoted word at its new target code.
            if text == rec.promoted then return true end
            -- If the displaced word has a generated fallback code, hide it from
            -- the original target code even when this started as a same-code move.
            if rec.new_code and rec.new_code ~= "" and text == rec.displaced then return true end
        end
    end

    local old_records = data.by_old[input]
    if old_records then
        -- Hide the promoted word from its old code.
        for _, rec in ipairs(old_records) do
            if text == rec.promoted then return true end
        end
    end

    local new_records = data.by_new[input]
    if new_records then
        -- 被挤者现在「住」在 new_code 上（translator 会在那里注入它），
        -- 所以要把它在同一个码上的**原生副本**藏掉，别同一个词出现两次。
        -- 键道规则下 new_code = base + 被挤者自己的形码，多数时候原生词库
        -- 里没有这个词条（如 ceelu），但碰上「被挤者原生码恰好就是它自己
        -- 的下一个形码位」时仍会重复，这里兜住。
        for _, rec in ipairs(new_records) do
            if rec.displaced and rec.displaced == text then return true end
        end
    end

    return false
end

function M.should_hide(input, text, cand_type, filename)
    return M.should_hide_loaded(M.load(filename), input, text, cand_type)
end

local function same_record(a, b)
    if not a or not b then return false end
    return a.promoted == b.promoted
        and a.old_code == b.old_code
        and a.displaced == b.displaced
        and a.target_code == b.target_code
        and (a.new_code or "") == (b.new_code or "")
end

local function format_record_line(promoted, old_code, displaced, target_code, new_code)
    local line = promoted .. "\t" .. old_code .. "\t" .. displaced .. "\t" .. target_code
    if new_code and new_code ~= "" then
        line = line .. "\t" .. new_code
    end
    return line
end

local function line_exists(lines, needle)
    for _, line in ipairs(lines or {}) do
        if line == needle then return true end
    end
    return false
end

local function add_text_chars(wanted, text)
    for _, ch in ipairs(split_chars(text)) do
        wanted[ch] = true
    end
end

local function merge_char_codes(into, extra)
    for ch, list in pairs(extra or {}) do
        if not into[ch] then into[ch] = {} end
        for _, code in ipairs(list) do
            local exists = false
            for _, old in ipairs(into[ch]) do
                if old == code then
                    exists = true
                    break
                end
            end
            if not exists then
                into[ch][#into[ch] + 1] = code
            end
        end
        table.sort(into[ch], function(a, b)
            if #a ~= #b then return #a > #b end
            return a < b
        end)
    end
end

local function ensure_char_codes_for_text(base_dir, char_codes, text)
    local wanted = {}
    add_text_chars(wanted, text)
    merge_char_codes(char_codes, load_char_codes(base_dir, wanted))
end

local function merge_occupied(into, extra)
    for code, texts in pairs(extra or {}) do
        if not into[code] then into[code] = {} end
        for text, present in pairs(texts) do
            if present then into[code][text] = true end
        end
    end
end

local function ensure_occupied_for_candidates(occupied, base_dir, candidates, exclude_pairs, existing_records)
    local target_codes = normalize_target_codes(candidates)
    if not target_codes then return end
    merge_occupied(occupied, M.load_occupied_codes_for_candidates(base_dir, target_codes, exclude_pairs))
    add_order_occupancy(occupied, existing_records, target_codes)
end

local function blocking_occupants(occupied, code, allowed_texts)
    local out = {}
    local occupants = occupied and occupied[code]
    if not occupants then return out end
    for text, present in pairs(occupants) do
        if present and not (allowed_texts and allowed_texts[text]) then
            out[#out + 1] = text
        end
    end
    table.sort(out)
    return out
end

local function copy_allowed(allowed_texts)
    local out = {}
    for text, present in pairs(allowed_texts or {}) do
        if present then out[text] = true end
    end
    return out
end

local function resolve_chain_new_code(moved_text, moved_old_code, target_code, char_codes,
                                      occupied, base_dir, exclude_pairs, existing_records,
                                      allowed_texts, depth)
    if depth < 0 then return nil, {} end
    ensure_char_codes_for_text(base_dir, char_codes, moved_text)
    local full = M.phrase_full_code(moved_text, target_code, char_codes)
    local candidates = M.candidate_new_codes(target_code, full)
    if #candidates == 0 then return nil, {} end
    ensure_occupied_for_candidates(occupied, base_dir, candidates, exclude_pairs, existing_records)

    local allowed = copy_allowed(allowed_texts)
    allowed[moved_text] = true
    for _, code in ipairs(candidates) do
        local blockers = blocking_occupants(occupied, code, allowed)
        if #blockers == 0 then
            add_occupied(occupied, moved_text, code)
            return code, {}
        end

        -- For explicit same-code toggles, keep the natural shortest fallback
        -- for the word being moved and bump the single word already occupying
        -- that code to its own next fallback:
        --   疲劳 -> pklzo, 疲痨(pklzo) -> pklzoo
        if depth > 0 and #blockers == 1 then
            local occupant = blockers[1]
            local next_allowed = copy_allowed(allowed)
            next_allowed[moved_text] = true
            local occupant_new_code, sub_chain = resolve_chain_new_code(
                occupant,
                code,
                code,
                char_codes,
                occupied,
                base_dir,
                exclude_pairs,
                existing_records,
                next_allowed,
                depth - 1
            )
            if occupant_new_code and occupant_new_code ~= "" then
                local chain = {
                    format_record_line(moved_text, moved_old_code, occupant, code, occupant_new_code)
                }
                for _, line in ipairs(sub_chain or {}) do
                    chain[#chain + 1] = line
                end
                add_occupied(occupied, moved_text, code)
                return code, chain
            end
        end
    end

    local code = M.choose_candidate_code(candidates, occupied, allowed)
    if code then add_occupied(occupied, moved_text, code) end
    return code, {}
end


-- ══ 「被挤者补码」时把**规则占位者**一起顺延（2026-09-27 第 10 轮） ═══════════
-- 背景：被挤者的键道落点 = 「自己形码前缀里最短的空位」。但那个位置可能不是被
-- **词库**占着（那是重码，键道规则允许、也不该为它写规则），而是被**别的调频规则**
-- 占着。那种占位者本身也是「上一轮被挤上来的」，应该一起顺延一位，把位置让回去。
--
-- 真机现场（用户第 10 轮）：
--   起始   ceel = 策说     ceeli = 侧说     ceelii = 从上市以来/从山上下来
--   ① 在 ceeli 按 0 → ceel = 侧说、ceeli = 从上市以来（级联补位）、ceelu = 策说
--   ② 再在 ceelu 按 0 → 策说回 ceel；被挤的侧说**本该回它自己的 ceeli**，
--      但 ceeli 此刻被规则「从上市以来」占着
--      ⇒ 旧行为直接跳过 ceeli，把侧说甩到第 3 位 ceelio（用户看到的「多了一位」）
--   用户要的：侧说 → ceeli，同时 从上市以来 → ceelii（各自顺延一位）。
--
-- 与 resolve_chain_new_code 的分工：
--   那个是 same_code 对调场景，会连**词库原生**占位者也顶走（疲劳/pklzo 那例）；
--   这里**只顶规则占位者** —— 词库原生的重码照旧跳过，不写多余规则。
--
-- 产出 chain 行的格式与 resolve_chain_new_code 完全一致：
--   「moved_text ⇥ moved_from_code ⇥ blocker ⇥ code ⇥ blocker_new_code」
-- 这一行同时起两个作用：① 把 moved_text 钉到 code（target_code = code）
-- ② 说明 blocker 被顶去了新码。target_code = code 还顺带触发 append_order 里
--   「同一 target_code 只留一条生效规则」的去重，把 blocker 原来那条规则删掉。
local function find_promoted_record(records, code, text)
    for _, rec in ipairs(records or {}) do
        if rec.target_code == code and rec.promoted == text then
            return rec
        end
    end
    return nil
end

local function resolve_displaced_chain(moved_text, moved_from_code, target_code,
                                       char_codes, occupied, base_dir, exclude_pairs,
                                       existing_records, allowed_texts, depth)
    if depth < 0 then return nil, {} end
    ensure_char_codes_for_text(base_dir, char_codes, moved_text)
    local full = M.phrase_full_code(moved_text, target_code, char_codes)
    local candidates = M.candidate_new_codes(target_code, full)
    if #candidates == 0 then return nil, {} end
    ensure_occupied_for_candidates(occupied, base_dir, candidates, exclude_pairs, existing_records)

    local allowed = copy_allowed(allowed_texts)
    allowed[moved_text] = true
    for _, code in ipairs(candidates) do
        if M.code_available(occupied, code, allowed) then
            add_occupied(occupied, moved_text, code)
            return code, {}
        end

        -- 这个码被挡着。挡它的如果**正好是一条调频规则**（且只有一条），
        -- 就把那条规则的词一起顺延一位，位置让出来。
        if depth > 0 then
            local blocker, count = nil, 0
            for text, present in pairs(occupied[code] or {}) do
                if present and not allowed[text] then
                    blocker = text
                    count = count + 1
                end
            end
            if blocker and count == 1 then
                local rec = find_promoted_record(existing_records, code, blocker)
                if rec then
                    local next_allowed = copy_allowed(allowed)
                    next_allowed[moved_text] = true
                    local blocker_new, sub_chain = resolve_displaced_chain(
                        blocker, code, code, char_codes, occupied, base_dir,
                        exclude_pairs, existing_records, next_allowed, depth - 1)
                    if blocker_new and blocker_new ~= "" then
                        local chain = { format_record_line(moved_text, moved_from_code,
                                                           blocker, code, blocker_new) }
                        for _, line in ipairs(sub_chain or {}) do
                            chain[#chain + 1] = line
                        end
                        add_occupied(occupied, moved_text, code)
                        return code, chain
                    end
                end
            end
        end
    end

    -- 兜底：候选全被规则占着（或顶不动）→ 退回原来的行为：挑最短「可用」的一位
    local code = M.choose_candidate_code(candidates, occupied, allowed)
    if code then add_occupied(occupied, moved_text, code) end
    return code, {}
end


function M.append_order(rec, path)
    if type(rec) ~= "table" then return false end
    local promoted = trim(rec.promoted)
    local old_code = trim(rec.old_code):lower()
    local displaced = trim(rec.displaced)
    local target_code = trim(rec.target_code):lower()
    local new_code = trim(rec.new_code):lower()
    if promoted == "" or displaced == "" or not is_code(old_code) or not is_code(target_code) then
        return false
    end
    if new_code ~= "" and not is_code(new_code) then
        new_code = ""
    end

    path = path or M.store_path(M.default_filename)
    local current_rec = {
        promoted = promoted,
        old_code = old_code,
        displaced = displaced,
        target_code = target_code,
        same_code = old_code == target_code,
    }
    if new_code ~= "" then
        current_rec.new_code = new_code
    end

    local lines = {}
    local existing_records = {}
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            lines[#lines + 1] = line
            local parsed = M.parse_line(line, 0)
            if parsed then
                existing_records[#existing_records + 1] = parsed
            end
        end
        f:close()
    end

    local inverse_same_code = nil
    for _, parsed in ipairs(existing_records) do
        if parsed.promoted == displaced and parsed.displaced == promoted
            and parsed.target_code == target_code and parsed.same_code
            and parsed.new_code and parsed.new_code ~= "" then
            inverse_same_code = parsed
            break
        end
    end

    local chain_lines = {}
    -- rec.no_auto_code = true：调用方已经自己算好了目标码，不需要这里再自动补码。
    -- 不传它的调用方（比如「0 = 编码档位前移一位」）走自动补码：
    --   字码表 + 占用表两次扫描。2026-09-27 起这两次扫描都优先走磁盘索引
    --   （<base_dir>/idx_candidate_order/），实测 1.15 s → 10 ms 级；
    --   索引缺失/过期会自动退回全量扫描，结果不变。
    if rec.no_auto_code ~= true and record_needs_new_code(current_rec) and new_code == "" then
        local wanted = {}
        for _, ch in ipairs(split_chars(displaced)) do
            wanted[ch] = true
        end
        local base_dir = M.user_data_dir()
        local char_codes = load_char_codes(base_dir, wanted)
        current_rec.full_code = M.phrase_full_code(displaced, target_code, char_codes)
        local new_codes = M.candidate_new_codes(target_code, current_rec.full_code)

        -- ── ★ 补码落点 = 键道规则：「被挤者取自己形码前缀里最短的空位」 ──────
        -- 这与参考软件（键道词库助手 `adjust_code` / `Encoder.suggest`）完全一致：
        --   码 = 音码 base + 形码 shape[:k]；被挤者从 k=0 起逐级多带一位**自己的**
        --   形码，谁没被占就用谁，全占满才落最长码（允许重码）。
        --   base 此刻已被 promoted 钉住 → 被挤者自然落到 base + 自己的首形码。
        --
        -- 真机实测（2026-09-27 第 5 轮，用户明确要求）：
        --   ceel = 策说（音码 ceel，形码 uo）／ ceeli = 侧说（音码 ceel，形码 io）
        --   在 ceeli 上按 0 → 侧说钉到 ceel → 策说取自己的下一个形码位 → **ceelu**
        --   （candidate_new_codes("ceel","ceeluo") = {ceelu, ceeluo} 的第一个）
        --
        -- ★ 不要图省事让被挤者去接管「被让出来的 old_code」。那是对调，不是键道
        --   规则；被挤者会落在一个**不属于它**的码上（策说跑到 ceeli），而且再按
        --   一次 0 也算不回它自己的码 —— 用户第 5 轮反馈的「无法再次前移一位」
        --   就是这么来的。old_code 空出来是**正常**的：方案自带的补全会在那里
        --   显示 ceelii 的词（从上市以来 ~i），这是 rime 原生行为，不是坏掉。
        current_rec._candidate_new_codes = new_codes
        local target_codes = normalize_target_codes(current_rec._candidate_new_codes)
        local occupied = {}
        if target_codes then
            occupied = M.load_occupied_codes_for_candidates(
                base_dir,
                target_codes,
                build_exclude_pairs(existing_records, current_rec)
            )
            add_order_occupancy(occupied, existing_records, target_codes)
        end
        if current_rec.same_code then
            new_code, chain_lines = resolve_chain_new_code(
                displaced,
                target_code,
                target_code,
                char_codes,
                occupied,
                base_dir,
                build_exclude_pairs(existing_records, current_rec),
                existing_records,
                { [promoted] = true },
                4
            )
            new_code = new_code or ""
        else
            -- ★ 第 10 轮：这里不再直接 choose_candidate_code —— 改走
            --   resolve_displaced_chain：除了挑自己最短的空位，还会把「占着那个位置
            --   的别的调频规则」一起顺延一位（chain_lines），让被挤者回到它自己的
            --   键道位置上。词库原生的重码不顶（那是键道规则允许的）。
            --   例：策说 ceelu→ceel 时，侧说回 ceeli，从上市以来 顺延到 ceelii。
            new_code, chain_lines = resolve_displaced_chain(
                displaced,
                target_code,
                target_code,
                char_codes,
                occupied,
                base_dir,
                build_exclude_pairs(existing_records, current_rec),
                existing_records,
                { [promoted] = true },
                4
            )
            new_code = new_code or ""
        end
        current_rec.new_code = new_code
    end

    local newline = format_record_line(promoted, old_code, displaced, target_code, new_code)

    -- 取一行记录的 target_code（第 4 字段）。用于下面「chain 行占的码也要清场」。
    local function line_target_code(line)
        local n = 0
        for field in (line or ""):gmatch("[^\t]*") do
            n = n + 1
            if n == 4 then return field:lower() end
        end
        return ""
    end

    -- chain 行各自也占一个 target_code（通常是「被顶走的那个词」原来占的码）：
    -- 该码上的旧规则必须一起让位。否则老规则按文件顺序取胜，会把刚顶下去的词
    -- 又拉回那个码上 —— 第 10 轮的反向操作（CEELU 按 0 原路换回）就靠这条成立。
    local chain_targets = {}
    for _, line in ipairs(chain_lines or {}) do
        local t = line_target_code(line)
        if t ~= "" then chain_targets[t] = true end
    end

    local kept_lines = {}
    local exists = false
    local upgraded_existing = false
    local removed_inverse = false
    local removed_stale_target = false
    for _, line in ipairs(lines) do
        local parsed = M.parse_line(line, 0)
        local drop_on_rewrite = false
        if parsed and parsed.promoted == promoted and parsed.old_code == old_code
            and parsed.displaced == displaced and parsed.target_code == target_code then
            exists = true
            if new_code ~= "" and (parsed.new_code or "") ~= new_code then
                upgraded_existing = true
                drop_on_rewrite = true
            end
        end
        -- A target code can only have one active promoted top candidate.
        -- If an older rule for the same target remains above the newly chosen
        -- one, it wins by file order and makes the hotkey look ineffective
        -- (pklz: old 疲劳/😪 stayed above new 皮佬/疲劳).
        if parsed and parsed.target_code == target_code and not drop_on_rewrite then
            local same_four_fields = parsed.promoted == promoted
                and parsed.old_code == old_code
                and parsed.displaced == displaced
                and parsed.target_code == target_code
            if not same_four_fields then
                removed_stale_target = true
                drop_on_rewrite = true
            end
        end
        -- Pressing the hotkey again on the displaced candidate should undo the
        -- previous promotion instead of appending an inverse rule like:
        --   A old B code
        --   B code A code
        -- The inverse rule makes both words fight for the same target code and
        -- can hide the original longer code of A.
        if parsed and parsed.promoted == displaced and parsed.displaced == promoted
            and parsed.target_code == target_code then
            removed_inverse = true
            drop_on_rewrite = true
        end
        -- chain 行占掉的码：同码旧规则一律让位（见上面 chain_targets 的注释）。
        if parsed and chain_targets[parsed.target_code] and not drop_on_rewrite then
            removed_stale_target = true
            drop_on_rewrite = true
        end
        -- 同一个词只允许被钉在**一个**码上：它又被前移/顺延到别处时，旧那条必须走。
        -- 第 10 轮的反向操作必须靠这条：chain 行会把「侧说」钉在 ceeli，
        -- 用户再在 ceeli 按 0 把侧说挪回 ceel 时，不删这条就会两处各钉一次。
        if parsed and parsed.promoted == promoted
            and parsed.target_code ~= target_code and not drop_on_rewrite then
            removed_stale_target = true
            drop_on_rewrite = true
        end
        if not drop_on_rewrite then
            kept_lines[#kept_lines + 1] = line
        end
    end

    if removed_inverse or upgraded_existing or removed_stale_target then
        local wf = io.open(path, "w")
        if not wf then return false end
        if #kept_lines > 0 then
            wf:write(table.concat(kept_lines, "\n"), "\n")
        end
        if upgraded_existing or inverse_same_code or not exists then
            wf:write(newline, "\n")
        end
        -- chain 行：same_code 对调（疲劳/pklzo）与第 10 轮的「规则占位者顺延」
        -- 都会产出，所以这里不再限 same_code。
        for _, line in ipairs(chain_lines or {}) do
            if not line_exists(kept_lines, line) and line ~= newline then
                wf:write(line, "\n")
                kept_lines[#kept_lines + 1] = line
            end
        end
        wf:close()
        clear_cache()
        return true
    end

    if exists then return true end

    local wf = io.open(path, "a")
    if not wf then return false end
    if #lines > 0 then
        local last = lines[#lines] or ""
        if last ~= "" then
            wf:write("\n")
        end
    end
    wf:write(newline, "\n")
    -- 纯追加这条路以前不需要 chain（只有 same_code 才产 chain，而 same_code 必然
    -- 走上面的 rewrite 分支）；第 10 轮之后普通前移也可能带 chain，这里补上。
    local appended = { newline }
    for _, line in ipairs(chain_lines or {}) do
        if not line_exists(lines, line) and not line_exists(appended, line)
            and line ~= newline then
            wf:write(line, "\n")
            appended[#appended + 1] = line
        end
    end
    wf:close()

    -- Force reload on next lookup even if mtime granularity is coarse.
    clear_cache()
    return true
end

function M.promote_prefix_fallback(prefix_rec, current_code, displaced_text, path)
    if type(prefix_rec) ~= "table" then return false end
    current_code = trim(current_code):lower()
    displaced_text = trim(displaced_text)
    local old_new_code = trim(prefix_rec.new_code):lower()
    if displaced_text == "" or not is_code(current_code) or not is_code(old_new_code) then
        return false
    end
    if old_new_code:sub(1, #current_code) ~= current_code or #current_code >= #old_new_code then
        return false
    end
    if current_code == prefix_rec.target_code then return false end
    if prefix_rec.displaced == displaced_text then return false end

    path = path or M.store_path(M.default_filename)
    local lines = {}
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            lines[#lines + 1] = line
        end
        f:close()
    end

    local original = {
        promoted = prefix_rec.promoted,
        old_code = prefix_rec.old_code,
        displaced = prefix_rec.displaced,
        target_code = prefix_rec.target_code,
        new_code = old_new_code,
    }
    local replacement = format_record_line(
        prefix_rec.promoted,
        prefix_rec.old_code,
        prefix_rec.displaced,
        prefix_rec.target_code,
        current_code
    )
    local swap_line = format_record_line(
        prefix_rec.displaced,
        old_new_code,
        displaced_text,
        current_code,
        old_new_code
    )

    local kept_lines = {}
    local updated = false
    local swap_exists = false
    for _, line in ipairs(lines) do
        local parsed = M.parse_line(line, 0)
        local drop = false
        if parsed and same_record(parsed, original) then
            kept_lines[#kept_lines + 1] = replacement
            updated = true
            drop = true
        end
        if parsed and parsed.promoted == prefix_rec.displaced
            and parsed.old_code == old_new_code
            and parsed.displaced == displaced_text
            and parsed.target_code == current_code then
            if (parsed.new_code or "") == old_new_code then
                swap_exists = true
            else
                -- Upgrade stale four-field/old swap rule below by appending
                -- the canonical five-field line once.
            end
            drop = true
        end
        if not drop then
            kept_lines[#kept_lines + 1] = line
        end
    end

    if not updated then return false end
    if not swap_exists then
        kept_lines[#kept_lines + 1] = swap_line
    end

    local wf = io.open(path, "w")
    if not wf then return false end
    if #kept_lines > 0 then
        wf:write(table.concat(kept_lines, "\n"), "\n")
    end
    wf:close()
    clear_cache()
    return true
end

local function normalize_text_set(texts)
    local set = {}
    if type(texts) == "string" then
        local text = trim(texts)
        if text ~= "" then set[text] = true end
        return set
    end
    if type(texts) ~= "table" then return set end
    for key, value in pairs(texts) do
        local text = nil
        if type(key) == "number" then
            text = value
        elseif value then
            text = key
        end
        text = trim(text)
        if text ~= "" then set[text] = true end
    end
    return set
end

local function has_text(set)
    for _ in pairs(set or {}) do return true end
    return false
end

local function normalize_code_set(codes)
    local set = {}
    if type(codes) == "string" then
        local code = trim(codes):lower()
        if is_code(code) then set[code] = true end
        return set
    end
    if type(codes) ~= "table" then return set end
    for key, value in pairs(codes) do
        local code = nil
        if type(key) == "number" then
            code = value
        elseif value then
            code = key
        end
        code = trim(code):lower()
        if is_code(code) then set[code] = true end
    end
    return set
end

local function has_code(set)
    for _ in pairs(set or {}) do return true end
    return false
end

local function is_chain_side_effect(rec, removed_rec)
    if not rec or not removed_rec then return false end
    local removed_new_code = removed_rec.new_code or ""
    -- Chain records are generated when a displaced word is moved to a fallback
    -- code that is already occupied:
    --   皮佬 pklz 疲劳 pklz pklzo
    --   疲劳 pklz 疲痨 pklzo pklzoo
    -- If the first line is removed, the second one should be removed too.
    if removed_new_code ~= "" and rec.promoted == removed_rec.displaced
        and rec.old_code == removed_rec.target_code
        and rec.target_code == removed_new_code then
        return true
    end
    -- Stale inverse records can remain after repeated same-code toggles:
    --   疲劳 pklz 疲痨 pklzo pklzoo
    --   疲劳 pklz 皮佬 pklz pklza
    -- Deleting 皮佬 removes the second line. The first line must be removed too,
    -- otherwise 疲劳 stays hidden from pklz even though the custom word is gone.
    return removed_rec.same_code
        and rec.promoted == removed_rec.promoted
        and rec.old_code == removed_rec.old_code
        and rec.target_code ~= removed_rec.target_code
end

function M.remove_record_and_dependents(record, path)
    if type(record) ~= "table" then return false, 0 end
    path = path or M.store_path(M.default_filename)

    local lines = {}
    local parsed_by_index = {}
    local f = io.open(path, "r")
    if not f then return true, 0 end
    for line in f:lines() do
        lines[#lines + 1] = line
        parsed_by_index[#lines] = M.parse_line(line, #lines)
    end
    f:close()

    local selected_index = nil
    local preferred_line = tonumber(record.line_no)
    if preferred_line and parsed_by_index[preferred_line]
        and same_record(parsed_by_index[preferred_line], record) then
        selected_index = preferred_line
    else
        for i = 1, #lines do
            local rec = parsed_by_index[i]
            if rec and same_record(rec, record) then
                selected_index = i
                break
            end
        end
    end
    if not selected_index then return true, 0 end

    local remove = { [selected_index] = true }
    local removed_records = { parsed_by_index[selected_index] }
    local changed = true
    while changed do
        changed = false
        for i = 1, #lines do
            local rec = parsed_by_index[i]
            if rec and not remove[i] then
                for _, removed_rec in ipairs(removed_records) do
                    if is_chain_side_effect(rec, removed_rec) then
                        remove[i] = true
                        removed_records[#removed_records + 1] = rec
                        changed = true
                        break
                    end
                end
            end
        end
    end

    local kept = {}
    for i, line in ipairs(lines) do
        if not remove[i] then kept[#kept + 1] = line end
    end

    local wf = io.open(path, "w")
    if not wf then return false, 0 end
    if #kept > 0 then wf:write(table.concat(kept, "\n"), "\n") end
    local ok = wf:close()
    if ok == false then return false, 0 end

    clear_cache()
    return true, #removed_records
end

function M.remove_records_for_texts(texts, path, codes)
    local text_set = normalize_text_set(texts)
    local code_set = normalize_code_set(codes)
    if not has_text(text_set) and not has_code(code_set) then return true, 0 end

    path = path or M.store_path(M.default_filename)
    local lines = {}
    local parsed_by_index = {}
    local f = io.open(path, "r")
    if not f then return true, 0 end
    for line in f:lines() do
        lines[#lines + 1] = line
        parsed_by_index[#lines] = M.parse_line(line, 0)
    end
    f:close()

    local remove = {}
    local removed_records = {}
    local changed = true
    while changed do
        changed = false
        for i = 1, #lines do
            local rec = parsed_by_index[i]
            if rec and not remove[i] then
                local should_remove = text_set[rec.promoted] or text_set[rec.displaced]
                if not should_remove and code_set[rec.old_code]
                    and rec.target_code:sub(1, #rec.old_code) == rec.old_code then
                    local moved_to_longer_code = rec.target_code ~= rec.old_code
                    local same_code_with_fallback = rec.target_code == rec.old_code
                        and rec.new_code and rec.new_code:sub(1, #rec.old_code) == rec.old_code
                        and rec.new_code ~= rec.old_code
                    if moved_to_longer_code or same_code_with_fallback then
                        should_remove = true
                    end
                end
                if not should_remove then
                    for _, removed_rec in ipairs(removed_records) do
                        if is_chain_side_effect(rec, removed_rec) then
                            should_remove = true
                            break
                        end
                    end
                end
                if should_remove then
                    remove[i] = true
                    removed_records[#removed_records + 1] = rec
                    changed = true
                end
            end
        end
    end

    local removed_count = #removed_records
    if removed_count == 0 then return true, 0 end

    local kept = {}
    for i, line in ipairs(lines) do
        if not remove[i] then
            kept[#kept + 1] = line
        end
    end

    local wf = io.open(path, "w")
    if not wf then return false, 0 end
    if #kept > 0 then
        wf:write(table.concat(kept, "\n"), "\n")
    end
    wf:close()
    clear_cache()
    return true, removed_count
end

function M.clear_cache()
    clear_cache()
    collectgarbage("collect")
end

-- ════════════════════════════════════════════════════════════════
-- 以下为 =tp 调频 translator（原 candidate_order.lua 主体，2026-09-14 合并）：
--   core 不再单独成文件；processor / filter 改用 require(...).core 取本表。
-- ════════════════════════════════════════════════════════════════
local core = M

local function get_store_file(env)
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        local file = env.engine.schema.config:get_string("candidate_order/store_file")
        if file and file ~= "" then return file end
    end
    return core.default_filename
end

local function make_candidate(seg, text, comment, quality, cand_type)
    local cand = Candidate(cand_type or "candidate_order", seg.start, seg._end, text, comment or "")
    cand.quality = quality or 260000
    return cand
end

local function management_query(input)
    if type(input) ~= "string" then return nil end
    return input:match("^=tp(.*)$")
end

local function management_comment(rec)
    local moved = "下移"
    if rec.new_code and rec.new_code ~= "" then moved = "→" .. rec.new_code end
    return "原码" .. rec.old_code .. "；" .. rec.displaced .. moved
        .. "〔调频·第" .. tostring(rec.line_no) .. "行·按0撤销〕"
end

local function yield_management_candidates(input, seg, env)
    local query = management_query(input)
    if query == nil then return false end

    local state = _G.__candidate_order_manager_state or {}
    local pending = state.pending_delete
    if pending and pending.input == input and pending.record then
        local rec = pending.record
        yield(make_candidate(
            seg,
            "确认撤销：" .. rec.target_code .. " / " .. rec.promoted,
            "恢复" .. rec.displaced .. "〔再按0确认，其他键取消〕",
            600000,
            "candidate_order_delete_confirm"
        ))
        return true
    end

    local notice = state.manager_notice
    if notice and notice.input == input and notice.message and notice.message ~= "" then
        yield(make_candidate(
            seg,
            notice.message,
            notice.ok and "〔调频管理〕" or "〔撤销失败〕",
            600000,
            "candidate_order_manager_notice"
        ))
    end

    local records = core.search_records(query, get_store_file(env))
    if #records == 0 then
        yield(make_candidate(
            seg,
            query == "" and "暂无动态调频" or "没有匹配的动态调频",
            "candidate_order.txt",
            500000,
            "candidate_order_manager_empty"
        ))
        return true
    end

    for i, rec in ipairs(records) do
        yield(make_candidate(
            seg,
            rec.target_code .. "：" .. rec.promoted .. "置顶",
            management_comment(rec),
            500000 - i,
            "candidate_order_manager"
        ))
    end
    return true
end

local function translator(input, seg, env)
    if type(input) ~= "string" or input == "" then return end
    if yield_management_candidates(input, seg, env) then return end
    if not core.is_enabled(env) then return end
    if not input:match("^[a-z]+$") then return end

    local target_records, new_records, data = core.records_for_input(input, get_store_file(env))

    if data and data.errors and #data.errors > 0 and input == "coerr" then
        for i, err in ipairs(data.errors) do
            yield(make_candidate(seg, err, "candidate_order.txt", 300000 - i))
        end
        return
    end

    -- ★ 第 10 轮：已经在本码被「置顶钉住」的词，别再走 new_records 再注入一遍。
    -- 场景：被挤者回到它自己的码（侧说 → ceeli）时，会同时产生两条记录 ——
    --   主记录（… 侧说 ceel **ceeli**）与推挤链行（侧说 ceel 从上市以来 **ceeli** ceelii）,
    -- 两条都说「侧说在 ceeli」⇒ 同一个词在同一个码上被注入两次（肉眼可见的重复项）。
    -- 置顶那条 quality 更高、语义也更准，所以 new_records 这边直接跳过它。
    local pinned = {}
    for _, rec in ipairs(target_records) do
        pinned[rec.promoted] = true
    end

    for i, rec in ipairs(target_records) do
        -- Promoted candidate should look natural: no "调频" prompt in the comment.
        yield(make_candidate(seg, rec.promoted, "", 280000 - i * 2))

        -- Keep the displaced original first candidate visible under the same input,
        -- but show the remaining completion in the comment, e.g. qzyw 下显示 兆运(~u).
        if rec.new_code and rec.new_code ~= "" then
            local hint = rec.new_code
            if rec.new_code:sub(1, #input) == input and #rec.new_code > #input then
                hint = "~" .. rec.new_code:sub(#input + 1)
            end
            yield(make_candidate(seg, rec.displaced, hint, 279999 - i * 2))
        end
    end

    for i, rec in ipairs(new_records) do
        if rec.new_code and rec.new_code:sub(1, #input) == input and not pinned[rec.displaced] then
            -- At the actual new code, do not show an extra prompt; at an
            -- intermediate prefix, mimic table completion and show the rest.
            -- Prefix completion must stay below normal table exact candidates
            -- (translator.initial_quality is 0), otherwise a displaced word can
            -- jump ahead of the real exact word at that prefix, e.g.
            -- ytyda: 源由 should stay above 缘由(~i).
            local hint = ""
            local quality = 270000 - i
            if #input < #rec.new_code then
                hint = "~" .. rec.new_code:sub(#input + 1)
                quality = -10 - i
            end
            yield(make_candidate(seg, rec.displaced, hint, quality))
        end
    end
end

-- ════════════════════════════════════════════════════════════════
-- 以下为 filter（原 candidate_order_filter.lua，2026-09-20 合并）：
--   隐藏 candidate_order.txt 中被挪走的原候选。
--   原先靠 require("xmjd6.candidate_order").core 拿核心表，合并后直接用 M。
-- ════════════════════════════════════════════════════════════════
local function filter(input, env)
    if not M.is_enabled(env) then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local context = env and env.engine and env.engine.context
    local code = context and context.input or ""
    local file = get_store_file(env)
    local data = M.load(file)

    -- 绝大多数编码没有动态调频规则，直接透传。尤其 bq/te 这类
    -- 候选很多的前缀，避免对每个候选重复做 mtime/索引检查。
    if not M.has_rules_for_input(data, code) then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    for cand in input:iter() do
        if not M.should_hide_loaded(data, code, cand.text, cand.type) then
            yield(cand)
        end
    end
end

-- ════════════════════════════════════════════════════════════════
-- 导出：librime-lua 的 raw_init 一律硬取 .func，schema 里的 @ 后缀
-- 只落进 env.name_space，不参与选函数。因此这里让 .func 自行分流：
--   translator 第 1 参是 string（input），filter 第 1 参是表（Translation）。
-- ════════════════════════════════════════════════════════════════
local function dispatch(first, second, third)
    if type(first) == "string" then
        return translator(first, second, third)
    end
    local ok, is_input = pcall(function() return type(first.iter) == "function" end)
    if ok and is_input then
        return filter(first, second)
    end
    -- processor 是独立文件 candidate_order_processor.lua，不会走这里
    return kNoop
end

return { func = dispatch, core = M, translator = translator, filter = filter }
