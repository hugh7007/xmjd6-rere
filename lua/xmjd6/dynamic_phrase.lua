-- dynamic_phrase_core.lua
-- Pure Lua helpers for the xmjd6 dynamic personal phrase store.
-- Store format: one UTF-8 entry per line: text<TAB>code

local M = {}

-- Cache for indexed entries
local cache = {
    path = nil,
    mtime = nil,
    fsize = nil,        -- 第十二轮三修：缓存键的第二维（字节数）
    entries = nil,      -- 原始词条数组
    by_code = nil,      -- 按编码索引: { [code] = { {text, code}, ... } }
    by_root = nil       -- 按编码前缀分桶: { [root] = { {text, code}, ... } }
}

M.default_filename = "dynamic_phrases.txt"

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_code_like(s)
    return type(s) == "string" and s:match("^[A-Za-z0-9;']+$") ~= nil
end

local function strip_execute_suffix(input)
    if type(input) ~= "string" then
        return input, false
    end
    if input:sub(-1) == ";" then
        return input:sub(1, -2), true
    end
    return input, false
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

local function normalize_commit_history(source)
    if type(source) == "table" then
        local out = {}
        for _, item in ipairs(source) do
            local s = trim(tostring(item or ""))
            if s ~= "" then
                out[#out + 1] = s
            end
        end
        return out
    end

    local s = trim(source)
    if s == "" then return {} end
    return { s }
end

function M.recent_commit_text(source, count)
    local history = normalize_commit_history(source)
    count = tonumber(count) or 1
    count = math.floor(count)
    if count < 1 then return "" end
    if #history == 0 then return "" end
    if count > #history then count = #history end

    local start = #history - count + 1
    local parts = {}
    for i = start, #history do
        parts[#parts + 1] = history[i]
    end
    return table.concat(parts)
end

function M.store_path(filename)
    filename = filename or M.default_filename
    if rime_api and rime_api.get_user_data_dir then
        local ok, dir = pcall(rime_api.get_user_data_dir)
        if ok and dir and dir ~= "" then
            return join_path(dir, filename)
        end
    end
    return filename
end

-- ════════════════════════════════════════════════════════════════
-- 缓存键 = (mtime, size)                  2026-09-28 第十二轮三修
--
-- ❗ 症状：外部工具（键道词库助手等）覆盖写回 dynamic_phrases.txt 后，
--          i 键 / 自造词「失效」（新词不出现、删掉的词还在），重新部署才恢复。
-- 根因：原来只比 lfs.attributes(path,"modification") —— **秒级精度**。
--       工具保存后 1 秒内打字 → mtime 数值没变 → 判定「文件没变」→ 用旧缓存。
--       重新部署之所以「能治」，是它重启引擎把内存缓存清了 —— 治标。
-- 修法：缓存键加第二维 size。同秒但字节数不同的覆盖（正是工具保存的真实场景，
--       几乎不可能恰好等字节）就能立刻察觉。
-- 遗留窗口：同秒 + 等字节（≤1 秒）仍察觉不到，这是 mtime 秒级精度的物理极限；
--       要突破只能每次按键都哈希全文（太贵）。1 秒后自愈。
-- ════════════════════════════════════════════════════════════════
local function file_size_of(path)
    local f = io.open(path, "rb")
    if not f then return -1 end
    local size = tonumber(f:seek("end"))
    f:close()
    return size or -1
end

local function file_stamp(path)
    local mtime = 0
    local lfs_ok, lfs = pcall(require, "lfs")
    if lfs_ok and lfs.attributes then
        local ok, attr = pcall(lfs.attributes, path, "modification")
        if ok and attr then
            mtime = attr
        end
    end
    -- 没有 lfs 时 mtime 恒为 0，靠 size 这一维仍然能发现大多数改动
    return tostring(mtime), file_size_of(path)
end

local function append_index(index, key, entry)
    if not key or key == "" then return end
    local list = index[key]
    if not list then
        list = {}
        index[key] = list
    end
    list[#list + 1] = entry
end

local function build_indexes(entries)
    local by_code = {}
    local by_root = {}
    for _, entry in ipairs(entries) do
        local code = entry.code
        append_index(by_code, code, entry)
        -- 参考 pantsu 的 root 分桶，但保持轻量：只建 2~4 码根。
        -- 精确查询仍走 by_code；前缀/占码类逻辑可先落到小桶再过滤。
        for len = 2, math.min(4, #code) do
            append_index(by_root, code:sub(1, len), entry)
        end
    end
    return by_code, by_root
end

local function clear_cache()
    cache.path = nil
    cache.mtime = nil
    cache.fsize = nil
    cache.entries = nil
    cache.by_code = nil
    cache.by_root = nil
end

do
    local ok, mem_cleaner = pcall(require, "xmjd6.mem_cleaner")
    if ok and mem_cleaner and mem_cleaner.register then
        mem_cleaner.register(clear_cache)
    end
end

local function get_cached_entries(path)
    path = path or M.store_path()
    local mtime, fsize = file_stamp(path)

    -- 三重比较：路径 + mtime + size（size 是第十二轮三修加的）
    if cache.path == path and cache.mtime == mtime and cache.fsize == fsize
        and cache.entries then
        return cache.entries, cache.by_code, cache.by_root
    end

    -- Cache miss or stale - reload and rebuild indexes
    local entries = M.load_entries_uncached(path)
    local by_code, by_root = build_indexes(entries)
    cache.path = path
    cache.mtime = mtime
    cache.fsize = fsize
    cache.entries = entries
    cache.by_code = by_code
    cache.by_root = by_root

    return entries, by_code, by_root
end

-- ════════════════════════════════════════════════════════════════
-- 多段上屏命令：'N'编码; / 'N编码;（数字后不写撇号）/ 'N'编码(码内含 ')
--                                              2026-09-28 第十二轮
--
-- ❗ 症状：用户按「' + 2 + 编码」录入，本以为取「最近 2 次上屏」，
--          实际只取了「最近 1 次」，而且数字被粘进了编码。
-- 真机复现（真 rime.dll 逐键回放，见 scripts/drive_real_rime.py 的 noprime 场景）：
--     '2'lztfuv;   → 老坛酸菜 @ lztfuv          ✅ 文档形式
--     '2lztfuv;    → 酸菜     @ 2lztfuv          ❌ 数字被当成码
--     '2'lz'tfuv;  → 2        @ lz'tfuv          ❌ 撇号被当成「词/码」分隔符
--   原因：原实现只认 `^(%d+)'([^']+)$` 一种写法；用户直觉写法（数字后直接
--         接码）与「码里带 ' 作音节分隔符」（speller/delimiter 允许）都落到
--         了后面的「text'code」或「整段当码」分支。
-- 修法：统一成一个多段匹配函数，按「越明确越优先」的顺序试三种写法。
--   ③ 那种（数字+字母直接相连）要求剩下的部分长得像键道码（只有小写字母/;/'），
--     这样 '3Q'abc（意图是「词=3Q、码=abc」）不会被误认成 N=3、码=Q'abc。
-- ════════════════════════════════════════════════════════════════
local function make_multi_chunk(digits, code, is_del, execute_suffix)
    code = trim(code)
    -- 允许用户把撇号也写进码里（'2'lz'tfuv），这里只剥掉紧邻数字的那一个
    if code:sub(1, 1) == "'" then
        code = trim(code:sub(2))
    end
    if code == "" then
        return nil, "编码不能为空"
    end
    return {
        action = is_del and "del" or "add",
        code = code,
        needs_last_commit = true,
        chunk_count = tonumber(digits) or 1,
        execute_suffix = execute_suffix,
    }
end

local function match_multi_chunk(arg, is_del, execute_suffix)
    -- ① N'code：码内不含撇号 —— 文档写法，最优先
    local digits, code = arg:match("^(%d+)'([^']+)$")
    if digits then
        return make_multi_chunk(digits, code, is_del, execute_suffix)
    end

    -- ② N'code：码内含撇号（键道音节分隔符），如 '2'lz'tfuv
    --    要求「码样子」：只由小写字母 ; ' 组成且至少有一个字母；数字最多 2 位。
    digits, code = arg:match("^(%d%d?)'(.+)$")
    if digits and code:match("^[a-z;']+$") and code:match("%a") then
        return make_multi_chunk(digits, code, is_del, execute_suffix)
    end

    -- ③ Ncode：数字后直接跟码，用户直觉写法，如 '2lztfuv
    digits, code = arg:match("^(%d%d?)([a-z][a-z;']*)$")
    if digits then
        return make_multi_chunk(digits, code, is_del, execute_suffix)
    end

    return nil
end

function M.is_dynamic_command(input)
    if type(input) ~= "string" then return false end
    input = strip_execute_suffix(input)
    -- Must start with ' (add) or '' (del). Bare ' alone is not a command.
    if input == "'" or input == "''" then return true end
    if input:sub(1, 2) == "''" then return true end
    if input:sub(1, 1) == "'" then return true end
    return false
end

function M.parse_command(input)
    if type(input) ~= "string" then
        return nil, "命令为空"
    end

    local execute_suffix = false
    input, execute_suffix = strip_execute_suffix(input)

    -- Determine action by leading apostrophes: '' = del, ' = add.
    local is_del = input:sub(1, 2) == "''"
    local is_add = not is_del and input:sub(1, 1) == "'"
    if not is_del and not is_add then
        return nil, "未知命令"
    end

    -- Strip the prefix ('' or ') to get the argument portion.
    local arg = is_del and input:sub(3) or input:sub(2)

    if is_add then
        -- ADD syntax (separator is '):
        --   '编码;            → add last commit to code
        --   'N'编码;          → add last N commits joined to code
        --   'N编码;           → 同上（数字后不写撇号的直觉写法）
        --   'N'编码(码含')    → 同上（码里可以有 ' 作音节分隔符）
        --   '词'编码;         → add text with code
        if arg == "" then
            return nil, "用法：'编码; 或 '词'编码; 或 'N'编码;"
        end

        -- Try: 三种多段写法统一走 match_multi_chunk
        local multi, multi_err = match_multi_chunk(arg, false, execute_suffix)
        if multi then return multi end
        if multi_err then return nil, multi_err end

        -- Try: text'code  (explicit text add)
        -- Use the first ' as separator; text is before it, code is after.
        local sep_pos = arg:find("'")
        if sep_pos and sep_pos > 1 then
            local text = trim(arg:sub(1, sep_pos - 1))
            local code = trim(arg:sub(sep_pos + 1))
            if text == "" then return nil, "词不能为空" end
            if code == "" then return nil, "编码不能为空" end
            return { action = "add", text = text, code = code, execute_suffix = execute_suffix }
        end

        -- No separator: treat entire arg as code, use last commit text
        local code = trim(arg)
        if code == "" then return nil, "编码不能为空" end
        -- 纯数字的「码」不可能是键道码：多半是漏写了第二个撇号（'2 而不是 '2'码）。
        -- 明说清楚，别静默写成 code=2 的词。
        if code:match("^%d+$") then
            return nil, "编码不能是纯数字：多段请写 'N'编码;（例：'2'lztfuv;）"
        end
        return { action = "add", code = code, needs_last_commit = true, execute_suffix = execute_suffix }
    end

    -- DEL syntax (separator is '):
    --   ''编码;           → delete all entries with this code
    --   ''词;             → delete all entries for this text
    --   ''词'编码;        → delete exact text+code pair
    --   ''N'编码; / ''N编码;  → delete using last N commits as text
    if arg == "" then
        return nil, "用法：''编码; 或 ''词; 或 ''词'编码;"
    end

    -- Try: 三种多段写法（与 ADD 同一套识别规则）
    local multi, multi_err = match_multi_chunk(arg, true, execute_suffix)
    if multi then return multi end
    if multi_err then return nil, multi_err end

    -- Try: text'code  (exact delete)
    local sep_pos = arg:find("'")
    if sep_pos and sep_pos > 1 then
        local text = trim(arg:sub(1, sep_pos - 1))
        local code = trim(arg:sub(sep_pos + 1))
        if text == "" then return nil, "词不能为空" end
        if code == "" then return nil, "编码不能为空" end
        return { action = "del", text = text, code = code, execute_suffix = execute_suffix }
    end

    -- No separator: could be code (if code-like) or text
    local single = trim(arg)
    if single == "" then return nil, "词或编码不能为空" end

    if is_code_like(single) and execute_suffix then
        -- ''code; → delete by code
        return { action = "del", code = single, by_code = true, execute_suffix = execute_suffix }
    end

    -- ''text; → delete by text (all codes)
    return { action = "del", text = single, single_arg = true, execute_suffix = execute_suffix }
end

function M.load_entries_uncached(path)
    path = path or M.store_path()
    local entries = {}
    local f = io.open(path, "r")
    if not f then
        return entries
    end

    for line in f:lines() do
        if line and line ~= "" and not line:match("^%s*#") then
            local text, code = line:match("^(.-)\t([^\t]+)")
            if text and code then
                text = trim(text)
                code = trim(code)
                if text ~= "" and code ~= "" then
                    entries[#entries + 1] = { text = text, code = code }
                end
            end
        end
    end
    f:close()
    return entries
end

function M.load_entries(path)
    local entries = get_cached_entries(path)
    return entries
end

function M.search_entries(query, path)
    query = trim(query)
    local code_query = query:lower()
    local out = {}
    for _, entry in ipairs(M.load_entries(path)) do
        if query == ""
            or entry.text:find(query, 1, true)
            or entry.code:lower():find(code_query, 1, true) then
            out[#out + 1] = { text = entry.text, code = entry.code }
        end
    end
    return out
end

function M.load_index(path)
    local entries, by_code, by_root = get_cached_entries(path)
    return {
        entries = entries,
        by_code = by_code or {},
        by_root = by_root or {},
    }
end

function M.save_entries(entries, path)
    path = path or M.store_path()
    local f, err = io.open(path, "w")
    if not f then
        return false, err or "无法写入动态词库"
    end

    f:write("# xmjd6 dynamic phrases\n")
    f:write("# text<TAB>code; edited by '/'' commands\n")
    for _, entry in ipairs(entries or {}) do
        if entry.text and entry.code and entry.text ~= "" and entry.code ~= "" then
            f:write(entry.text, "\t", entry.code, "\n")
        end
    end
    local ok, close_err = f:close()
    if ok == false then
        return false, close_err or "保存动态词库失败"
    end

    -- Clear cache after saving to force reload on next access
    clear_cache()

    return true
end

local function same_entry(a, b)
    return a.text == b.text and a.code == b.code
end

local function cleanup_candidate_order_for_deleted_texts(texts, candidate_order_path, codes)
    if type(texts) ~= "table" then texts = {} end
    local has_any = false
    for text, present in pairs(texts) do
        if present and trim(text) ~= "" then
            has_any = true
            break
        end
    end
    local has_code = false
    if type(codes) == "string" and trim(codes) ~= "" then
        has_code = true
    elseif type(codes) == "table" then
        for _, code in pairs(codes) do
            if trim(code) ~= "" then
                has_code = true
                break
            end
        end
    end
    if not has_any and not has_code then return 0 end

    local ok_core, candidate_order_mod = pcall(require, "xmjd6.candidate_order")
    local candidate_order_core = ok_core and candidate_order_mod and candidate_order_mod.core or nil
    if not ok_core or not candidate_order_core or not candidate_order_core.remove_records_for_texts then
        return 0
    end

    local path = candidate_order_path
    if not path or path == "" then
        path = candidate_order_core.store_path(candidate_order_core.default_filename)
    end
    local ok, _, removed = pcall(candidate_order_core.remove_records_for_texts, texts, path, codes)
    if ok then return tonumber(removed) or 0 end
    return 0
end

local function append_candidate_order_cleanup_message(message, removed)
    removed = tonumber(removed) or 0
    if removed > 0 then
        return message .. "；同步清理调频" .. tostring(removed) .. "条"
    end
    return message
end

function M.add_phrase(text, code, path)
    text = trim(text)
    code = trim(code)
    if text == "" then return false, "词不能为空" end
    if code == "" then return false, "编码不能为空" end

    local entries = M.load_entries(path)
    local new_entry = { text = text, code = code }
    local exists = false
    for _, entry in ipairs(entries) do
        if same_entry(entry, new_entry) then
            exists = true
            break
        end
    end
    if not exists then
        entries[#entries + 1] = new_entry
    end

    local ok, err = M.save_entries(entries, path)
    if not ok then return false, err end
    if exists then
        return true, "已存在：" .. text .. " / " .. code, 0
    end
    return true, "已添加：" .. text .. " / " .. code, 1
end

function M.delete_phrase(text, code, path, candidate_order_path)
    text = trim(text)
    code = code and trim(code) or nil
    if text == "" then return false, "词不能为空" end
    if code == "" then return false, "编码不能为空" end

    local entries = M.load_entries(path)
    local kept = {}
    local removed = 0
    local deleted_texts = {}
    for _, entry in ipairs(entries) do
        local matches = entry.text == text and (not code or entry.code == code)
        if matches then
            removed = removed + 1
            deleted_texts[entry.text] = true
        else
            kept[#kept + 1] = entry
        end
    end

    local ok, err = M.save_entries(kept, path)
    if not ok then return false, err, removed end
    -- If the dynamic entry was already deleted in a previous run/version, an
    -- explicit ''词[/码] should still clean candidate_order.txt. Otherwise a
    -- stale tuning record can resurrect the removed custom word.
    local cleanup_texts = deleted_texts
    cleanup_texts[text] = true
    local co_removed = cleanup_candidate_order_for_deleted_texts(cleanup_texts, candidate_order_path, code)
    if removed == 0 then
        return true, append_candidate_order_cleanup_message(
            "未找到：" .. text .. (code and (" / " .. code) or ""),
            co_removed
        ), 0
    end
    return true, append_candidate_order_cleanup_message(
        "已删除" .. removed .. "条：" .. text .. (code and (" / " .. code) or ""),
        co_removed
    ), removed
end

function M.delete_by_code(code, path, candidate_order_path)
    code = trim(code)
    if code == "" then return false, "编码不能为空" end

    local entries = M.load_entries(path)
    local kept = {}
    local removed = 0
    local deleted_texts = {}
    for _, entry in ipairs(entries) do
        if entry.code == code then
            removed = removed + 1
            deleted_texts[entry.text] = true
        else
            kept[#kept + 1] = entry
        end
    end

    local ok, err = M.save_entries(kept, path)
    if not ok then return false, err, removed end
    local co_removed = cleanup_candidate_order_for_deleted_texts(deleted_texts, candidate_order_path, code)
    if removed == 0 then
        return true, append_candidate_order_cleanup_message("未找到编码：" .. code, co_removed), 0
    end
    return true, append_candidate_order_cleanup_message(
        "已删除" .. removed .. "条编码：" .. code,
        co_removed
    ), removed
end

function M.resolve_command(input, commit_history)
    local cmd, err = M.parse_command(input)
    if not cmd then
        return nil, err or "命令格式错误"
    end
    if cmd.action == "add" and cmd.needs_last_commit then
        local text = M.recent_commit_text(commit_history, cmd.chunk_count or 1)
        if text == "" then
            return nil, "先打出要加的词，再输入 '编码; 或 'N'编码;"
        end
        cmd.text = text
        cmd.from_last_commit = true
    elseif cmd.action == "del" and cmd.needs_last_commit then
        local text = M.recent_commit_text(commit_history, cmd.chunk_count or 1)
        if text == "" then
            return nil, "先打出要删的词，再输入 ''N'编码;"
        end
        cmd.text = text
        cmd.from_last_commit = true
    elseif cmd.action == "del" and cmd.single_arg and not cmd.by_code then
        -- ''text; without execute suffix: if code-like, try to use last commit as text
        if is_code_like(cmd.text) then
            local text = M.recent_commit_text(commit_history, 1)
            if text ~= "" then
                cmd.code = cmd.text
                cmd.text = text
                cmd.from_last_commit = true
            end
        end
    end
    return cmd
end

function M.apply_resolved_command(cmd, path, candidate_order_path)
    if not cmd then
        return false, "命令格式错误", 0
    end
    if cmd.action == "add" then
        return M.add_phrase(cmd.text, cmd.code, path)
    elseif cmd.action == "del" then
        if cmd.by_code then
            return M.delete_by_code(cmd.code, path, candidate_order_path)
        end
        return M.delete_phrase(cmd.text, cmd.code, path, candidate_order_path)
    end
    return false, "未知命令", 0
end

function M.apply_command(input, path, last_commit_text, candidate_order_path)
    local cmd, err = M.resolve_command(input, last_commit_text)
    if not cmd then
        return false, err or "命令格式错误", 0
    end
    return M.apply_resolved_command(cmd, path, candidate_order_path)
end

function M.lookup(code, path)
    code = trim(code)
    if code == "" then return {} end

    local _, by_code = get_cached_entries(path)
    return by_code[code] or {}
end

local function prefix_root(prefix)
    if type(prefix) ~= "string" then return "" end
    if #prefix < 2 then return "" end
    return prefix:sub(1, math.min(4, #prefix))
end

function M.lookup_prefix(prefix, path, limit)
    prefix = trim(prefix)
    if prefix == "" then return {} end
    limit = limit or 50

    local index = M.load_index(path)
    local root = prefix_root(prefix)
    local entries = (root ~= "" and index.by_root[root]) or index.entries
    local matches = {}
    for _, entry in ipairs(entries) do
        if entry.code:sub(1, #prefix) == prefix then
            matches[#matches + 1] = entry
            if #matches >= limit then break end
        end
    end
    return matches
end

local function pair_key(text, code)
    return tostring(text or "") .. "\t" .. tostring(code or "")
end

local function normalize_codes(codes)
    if not codes then return nil end
    local out = {}
    local has_any = false
    for key, value in pairs(codes) do
        local code = nil
        if type(key) == "number" then
            code = value
        elseif value then
            code = key
        end
        code = trim(code)
        if code ~= "" then
            out[code] = true
            has_any = true
        end
    end
    if not has_any then return nil end
    return out
end

function M.load_occupied_for_codes(path, codes, exclude_pairs)
    local target_codes = normalize_codes(codes)
    local occupied = {}
    local index = M.load_index(path)

    local function add(text, code)
        text = trim(text)
        code = trim(code)
        if text == "" or code == "" then return end
        if exclude_pairs and exclude_pairs[pair_key(text, code)] then return end
        local bucket = occupied[code]
        if not bucket then
            bucket = {}
            occupied[code] = bucket
        end
        bucket[text] = true
    end

    if target_codes then
        for code in pairs(target_codes) do
            for _, entry in ipairs(index.by_code[code] or {}) do
                add(entry.text, entry.code)
            end
        end
    else
        for _, entry in ipairs(index.entries or {}) do
            add(entry.text, entry.code)
        end
    end

    return occupied
end

function M.command_preview(input, last_commit_text)
    local cmd, err = M.resolve_command(input, last_commit_text)
    if not cmd then
        return nil, err
    end
    if cmd.action == "add" then
        local prefix = cmd.from_last_commit and "添加刚上屏：" or "添加词："
        return prefix .. cmd.text, cmd.code
    elseif cmd.action == "del" then
        if cmd.by_code then
            return "删除编码：" .. cmd.code, "全部自造词"
        end
        local prefix = cmd.from_last_commit and "删除刚上屏：" or "删除词："
        return prefix .. cmd.text, cmd.code or "全部编码"
    end
    return nil, "未知命令"
end

-- Public API to manually clear cache (useful for debugging or external updates)
function M.clear_cache()
    clear_cache()
end

-- ════════════════════════════════════════════════════════════════
-- 以下为 '词'编码; 动态自造词 translator（原 dynamic_phrase.lua 主体，2026-09-14 合并）：
--   core 不再单独成文件；processor 改用 require(...).core 取本表。
-- ════════════════════════════════════════════════════════════════
local core = M

-- 自造词专用：读**强过滤**的那份 add_history（第十二轮二修）。
-- 老状态/首启时没有 add_history → 回退 commit_history，行为不会更差。
local function get_commit_history()
    local state = _G.__dynamic_phrase_state
    if not state then return {} end
    return state.add_history
        or state.commit_history
        or (state.last_commit_text and { state.last_commit_text })
        or {}
end

local function get_store_path(env)
    local file = nil
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        file = env.engine.schema.config:get_string("dynamic_phrase/store_file")
    end
    return core.store_path(file or core.default_filename)
end

local function make_candidate(seg, text, comment, quality, cand_type)
    local cand = Candidate(cand_type or "dynamic_phrase", seg.start, seg._end, text, comment or "")
    cand.quality = quality or 200000
    return cand
end

local function command_candidate(input, seg)
    local preview, comment = core.command_preview(input, get_commit_history())
    if preview then
        return make_candidate(seg, preview, (comment or "") .. "  末尾加 ; 执行；空格/回车也可", 300000)
    end

    if core.is_dynamic_command(input) then
        local _, err = core.parse_command(input)
        -- When input is bare ' or '', the candidate text should be the literal
        -- input so that space/enter commits the apostrophe(s), not the hint.
        -- The hint text goes into the comment instead.
        if input == "'" or input == "''" then
            return make_candidate(seg, input, err or "动态词命令", 300000)
        end
        return make_candidate(seg, err or "动态词命令", "单段 '码; 多段 'N'码 或 'N码; 末尾 ; 执行", 300000)
    end

    return nil
end

local function management_query(input)
    if type(input) ~= "string" then return nil end
    return input:match("^'''([^';]*)$")
end

local function yield_management_candidates(input, seg, env)
    local query = management_query(input)
    if query == nil then return false end

    local state = _G.__dynamic_phrase_state or {}
    local pending = state.pending_delete
    if pending and pending.input == input then
        yield(make_candidate(
            seg,
            "确认删除：" .. pending.text,
            pending.code .. "〔再按'确认，其他键取消〕",
            400000,
            "dynamic_phrase_delete_confirm"
        ))
        return true
    end

    local notice = state.manager_notice
    if notice and notice.input == input and notice.message and notice.message ~= "" then
        yield(make_candidate(
            seg,
            notice.message,
            notice.ok and "〔自造词管理〕" or "〔删除失败〕",
            500000,
            "dynamic_phrase_manager_notice"
        ))
    end

    local entries = core.search_entries(query, get_store_path(env))
    if #entries == 0 then
        if query == "" then
            yield(make_candidate(
                seg,
                "暂无自造词",
                "dynamic_phrases.txt 为空",
                400000,
                "dynamic_phrase_manager_empty"
            ))
        else
            local cmd_cand = command_candidate(input, seg)
            if cmd_cand then yield(cmd_cand) end
        end
        return true
    end

    for i, entry in ipairs(entries) do
        yield(make_candidate(
            seg,
            entry.text,
            entry.code .. "〔自造·按'删除〕",
            400000 - i,
            "dynamic_phrase_manager"
        ))
    end
    return true
end

local function translator(input, seg, env)
    if type(input) ~= "string" or input == "" then
        return
    end

    if yield_management_candidates(input, seg, env) then
        return
    end

    local cmd_cand = command_candidate(input, seg)
    if cmd_cand then
        yield(cmd_cand)
        return
    end

    -- Do not treat non-code special commands as dynamic phrase codes.
    local first = input:sub(1, 1)
    if first == "=" or first == "\\" or first == "&" or first == "/" then
        return
    end
    -- Skip when input is just apostrophes without ; or / (sentence-mode input).
    if first == "'" and not core.is_dynamic_command(input) then
        return
    end

    local matches = core.lookup(input, get_store_path(env))
    for i, entry in ipairs(matches) do
        local cand = make_candidate(seg, entry.text, entry.code .. "〔自造〕", 250000 - i)
        yield(cand)
    end
end


-- ════════════════════════════════════════════════════════════════
-- 以下为 processor（原 dynamic_phrase_processor.lua，2026-09-20 合并）：
--   空格/回车确认执行 '/'' 动态词命令；''' 管理模式（列出词条，按 0 删除）。
--   原先靠 require("xmjd6.dynamic_phrase").core 拿核心表，合并后直接用 M。
-- ════════════════════════════════════════════════════════════════
local kAccepted = 1
local kNoop = 2

local dp_state = _G.__dynamic_phrase_state or {}
_G.__dynamic_phrase_state = dp_state
local function dp_get_store_path(env)
    local file = nil
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        file = env.engine.schema.config:get_string("dynamic_phrase/store_file")
    end
    return core.store_path(file or core.default_filename)
end

local function dp_get_candidate_order_store_path(env)
    local file = nil
    if env and env.engine and env.engine.schema and env.engine.schema.config then
        file = env.engine.schema.config:get_string("candidate_order/store_file")
    end
    return core.store_path(file or "candidate_order.txt")
end

local function key_to_char(key)
    local ch = key and key.keycode
    if not ch or ch < 0x20 or ch >= 0x7f then
        return nil
    end
    return string.char(ch)
end

local function is_execute_suffix_key(key)
    if key_to_char(key) == ";" then
        return true
    end
    local repr = key and key.repr and key:repr() or ""
    return repr == "semicolon"
end

local function is_confirm_key(key)
    if not key then return false end
    if is_execute_suffix_key(key) then
        return true
    end
    if key.keycode == 0x20 or key.keycode == 0x0d or key.keycode == 0x0a then
        return true
    end
    local repr = key.repr and key:repr() or ""
    return repr == "space" or repr == "Return" or repr == "KP_Enter" or repr == "semicolon"
end

local function is_delete_key(key)
    if not key or key:release() or key:ctrl() or key:alt() or key:super() then
        return false
    end
    local repr = key.repr and key:repr() or ""
    return key.keycode == string.byte("'") or repr == "apostrophe"
end

local function dp_management_query(input)
    if type(input) ~= "string" then return nil end
    return input:match("^'''([^';]*)$")
end

local function refresh_context(context)
    if context and type(context.refresh_non_confirmed_composition) == "function" then
        pcall(function() context:refresh_non_confirmed_composition() end)
    end
end

local function selected_manager_entry(context)
    if not context or type(context.get_selected_candidate) ~= "function" then
        return nil
    end
    local ok, cand = pcall(function() return context:get_selected_candidate() end)
    if not ok or not cand or cand.type ~= "dynamic_phrase_manager" then
        return nil
    end
    local text = cand.text or ""
    local comment = cand.comment or ""
    local code = comment:match("^(.-)〔自造·按'删除〕$")
    if text == "" or not code or code == "" then return nil end
    return { text = text, code = code }
end

local function is_management_status_candidate(cand)
    if not cand or not cand.type then return false end
    return cand.type == "dynamic_phrase_manager_empty"
        or cand.type == "dynamic_phrase_manager_notice"
        or cand.type == "dynamic_phrase_delete_confirm"
end

local function cancel_stale_manager_state(context, key_is_delete)
    local input = context and context.input or ""
    local pending = dp_state.pending_delete
    if pending and pending.input ~= input then
        dp_state.pending_delete = nil
        refresh_context(context)
        return key_is_delete
    end
    if pending and not key_is_delete then
        dp_state.pending_delete = nil
        refresh_context(context)
    end
    local notice = dp_state.manager_notice
    if notice and notice.input ~= input then
        dp_state.manager_notice = nil
    elseif notice and not key_is_delete then
        dp_state.manager_notice = nil
    end
    return false
end

local function handle_manager_zero(context, env)
    local input = context and context.input or ""
    if dp_management_query(input) == nil then return kNoop end

    local pending = dp_state.pending_delete
    if pending and pending.input == input then
        local ok, message = core.delete_phrase(
            pending.text,
            pending.code,
            dp_get_store_path(env),
            dp_get_candidate_order_store_path(env)
        )
        dp_state.pending_delete = nil
        dp_state.manager_notice = {
            input = input,
            message = ok and (message or "删除完成")
                or ("删除失败：" .. (message or "无法写入动态词库")),
            ok = ok == true,
        }
        refresh_context(context)
        return kAccepted
    end

    local entry = selected_manager_entry(context)
    if entry then
        dp_state.pending_delete = {
            input = input,
            text = entry.text,
            code = entry.code,
        }
        dp_state.manager_notice = nil
        refresh_context(context)
    end
    -- Always swallow 0 in management mode so it cannot select/commit a helper candidate.
    return kAccepted
end

-- 自造词专用：读**强过滤**的那份 add_history（第十二轮二修）
local function dp_get_commit_history()
    return dp_state.add_history
        or dp_state.commit_history
        or (dp_state.last_commit_text and { dp_state.last_commit_text })
        or {}
end

-- ════════════════════════════════════════════════════════════════
-- 上屏历史卫生（2026-09-28 第十二轮）
--
-- ❗ 症状：'N'编码 录进来的不是「最近 N 次上屏」，而是一段乱七八糟的文本。
-- 真机复现（真 rime.dll 逐键回放，scripts/drive_real_rime.py 的 sweep / rawcode 场景），
-- 以下按键都会把「不是用户想上屏的词」塞进 commit_history：
--     · 空码 + 空格/回车 …… 上屏的是**原码**（例：打 lztfuv 得空码，空格后上屏 lztfuv）
--     · 裸撇号 ' / '' + 空格 … 上屏撇号本身
--     · 空码下的 . ; 等符号 … 上屏符号
--     · 自造词自己的提示候选（「添加刚上屏：X」「编码不能为空」…）被选重上屏
--   实测后果：先「空码上屏 lztfuv」再打 '2'abc; → 词条变成「lztfuv酸菜」。
--
-- 修法：remember_commit_text 只收「像是用户有意上屏的词」：
--   ① 提示/状态类文本一律不收（is_helper_text）；
--   ② 纯撇号、纯标点不收；
--   ③ 空码上屏原码不收 —— processor 在确认键按下那一刻留快照
--      （input + 当时是否有候选），上屏文本正好等于 input 且当时无候选 ⇒ 丢弃。
--      「有候选」的正常上屏永远是候选文本 ≠ input，不受影响。
-- ════════════════════════════════════════════════════════════════
-- 标点集合：半角 + 全角都收（按 UTF-8 码点切，不能按字节判）
local PUNCT_SET = {}
do
    local PUNCTS = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ \t\r\n"
        .. "。，、；：？！…—～·《》〈〉「」『』【】〔〕（）［］｛｝“”‘’　"
    if utf8 and utf8.codes then
        for _, cp in utf8.codes(PUNCTS) do
            PUNCT_SET[utf8.char(cp)] = true
        end
    end
end

local function is_all_punct(t)
    if type(t) ~= "string" or t == "" then return false end
    if not (utf8 and utf8.codes and utf8.char and utf8.len) then
        -- 没有 utf8 库时退回 ASCII 判据
        return t:match("^[%p%s]+$") ~= nil
    end
    if utf8.len(t) == nil then return false end
    for _, cp in utf8.codes(t) do
        if not PUNCT_SET[utf8.char(cp)] then return false end
    end
    return true
end

-- 纯提示/状态文本（面板自己吐出来的话），两份历史都要滤掉。
-- 第十二轮二修从 is_helper_text 拆出来单独一个函数：
--   commit_history 只滤这一层（旧语义：标点/撇号/空码原码照记）
--   add_history   还要额外滤掉撇号/标点/空码原码
local function is_notice_text(text)
    local t = trim(text)
    if t == "" then return true end
    -- 自造词 / 面板自己的提示与状态
    if t:match("^添加刚上屏[:：]") or t:match("^添加词[:：]")
        or t:match("^删除刚上屏[:：]") or t:match("^删除词[:：]")
        or t:match("^删除编码[:：]") or t:match("^确认删除[:：]")
        or t:match("^已添加") or t:match("^已删除") or t:match("^未找到")
        or t:match("^同步清理调频") or t:match("^先打出要加的词")
        or t:match("^先打出要删的词") or t:match("^用法[:：]")
        or t:match("^单段 ") or t:match("^编码不能为空") or t:match("^词不能为空")
        or t:match("^词或编码不能为空") or t:match("^编码不能是纯数字")
        or t:match("^编码不能包含") or t:match("^未知命令")
        or t:match("^动态词命令") or t:match("^暂无自造词") then
        return true
    end
    return false
end

-- 强过滤（自造词 / 'N编码 用）：提示文本 + 纯撇号 + 纯标点
local function is_helper_text(text)
    if is_notice_text(text) then return true end
    local t = trim(text)
    -- 纯撇号
    if t:match("^'+$") then return true end
    -- 纯标点/空白（半角 + 全角都要算，所以按码点而不是按字节判）
    if is_all_punct(t) then return true end
    return false
end

-- ════════════════════════════════════════════════════════════════
-- 两份历史（2026-09-28 第十二轮二修）
--
-- ❗ 教训：**一份共享状态不能同时伺候两个过滤需求相反的主人。**
--   · 「重复上屏」（i / =join / =wrap）要**脏数据** —— 用户按过什么就该能重复什么，
--     包括裸撇号、标点、空码上屏的原码。
--   · 「拼词」（自造词 'N编码）要**净数据** —— 垃圾必须挡在门外。
--   一修把两类非用户文本一起踢出 commit_history，i 键跟着受损（i 不能重复原码）。
--
-- 修法：remember_commit_text 维护两份历史 ——
--   commit_history : 只滤提示文本（is_notice_text）＝旧语义   → i / =join / =wrap 读
--   add_history    : 强过滤 + 不吃空码原码                    → 自造词读（回退 commit_history）
-- ════════════════════════════════════════════════════════════════
local HISTORY_MAX = 8

local function push_history(list, committed)
    list[#list + 1] = committed
    while #list > HISTORY_MAX do
        table.remove(list, 1)
    end
end

local function remember_commit_text(committed)
    if type(committed) ~= "string" or committed == "" then
        return
    end

    -- 空码上屏原码：确认键那一刻有快照、当时没有候选、上屏内容 == 输入串
    local pre = dp_state.pre_commit
    dp_state.pre_commit = nil
    local is_raw_code = pre and type(pre.input) == "string" and pre.input ~= ""
        and committed == pre.input and not pre.has_candidate

    -- ① commit_history（i / =join / =wrap）：只滤提示文本
    if not is_notice_text(committed) then
        dp_state.last_commit_text = committed
        dp_state.commit_history = dp_state.commit_history or {}
        push_history(dp_state.commit_history, committed)
    end

    -- ② add_history（自造词 'N编码）：强过滤，且不吃空码原码
    if is_raw_code or is_helper_text(committed) then
        return
    end
    dp_state.add_history = dp_state.add_history or {}
    push_history(dp_state.add_history, committed)
end

local function processor(key, env)
    if not key or key:release() or key:ctrl() or key:alt() or key:super() then
        return kNoop
    end

    local context = env and env.engine and env.engine.context
    if not context then
        return kNoop
    end

    -- Management mode: 0 deletes, other keys cancel stale state.
    local key_is_delete = is_delete_key(key)
    if cancel_stale_manager_state(context, key_is_delete) then
        return kAccepted
    end
    if key_is_delete then
        return handle_manager_zero(context, env)
    end

    local input = context.input or ""
    local in_management = dp_management_query(input) ~= nil

    -- In management mode, swallow ; to prevent command execution.
    -- Space and Return fall through to selector/express_editor so the
    -- highlighted candidate or literal ''' can be committed normally.
    if is_execute_suffix_key(key) and in_management then
        return kAccepted
    end

    if not is_confirm_key(key) then
        -- 非确认键：清掉上一次的快照，免得它误判后面的顶功/选重上屏
        dp_state.pre_commit = nil
        return kNoop
    end

    -- ★ 确认键（空格/回车/;）按下这一刻留快照，供 remember_commit_text 判断
    --   这次上屏是不是「空码上屏原码」。详见 remember_commit_text 顶部注释。
    do
        local has_candidate = false
        if type(context.get_selected_candidate) == "function" then
            local ok, cand = pcall(function() return context:get_selected_candidate() end)
            has_candidate = ok and cand ~= nil
        end
        dp_state.pre_commit = { input = input, has_candidate = has_candidate }
    end

    -- Space/Return in management mode: fall through (do not resolve as command)
    if in_management then
        -- Enter on bare ''' commits the literal three-apostrophe string directly,
        -- regardless of which candidate is highlighted. Mirrors the '' apostrophe
        -- behavior: space commits the highlighted candidate (first dynamic phrase),
        -- while Enter commits the symbol ''' itself. Functional sub-states
        -- (delete confirm / notice) keep their current behavior.
        local k = key.keycode
        local repr = key.repr and key:repr() or ""
        local is_return = (k == 0x0d or repr == "Return" or repr == "KP_Enter")
        if is_return and input == "'''" then
            local pd = dp_state.pending_delete
            local mn = dp_state.manager_notice
            if not (pd and pd.input == input) and not (mn and mn.input == input) then
                env.engine:commit_text("'''")
                context:clear()
                return kAccepted
            end
        end
        -- If the highlighted candidate is a status message (empty list, delete
        -- notice, or delete confirm), close the window instead of committing it.
        local ok, selected = pcall(function() return context:get_selected_candidate() end)
        if ok and selected and is_management_status_candidate(selected) then
            context:clear()
            return kAccepted
        end
        return kNoop
    end

    local command_input = input
    if is_execute_suffix_key(key) then
        command_input = input .. ";"
    end
    if not core.is_dynamic_command(command_input) then
        return kNoop
    end

    local cmd = core.resolve_command(command_input, dp_get_commit_history())
    if not cmd then
        -- If the input is just bare apostrophes (' or '') and user presses
        -- space/enter (not ;), let the event fall through to selector /
        -- express_editor so that:
        --   - with candidates: space/enter commits the highlighted candidate
        --   - without candidates: space/enter commits the literal input
        if not is_execute_suffix_key(key) and (input == "'" or input == "''") then
            return kNoop
        end
        -- Keep the composition editable, but swallow confirm so usage candidates are not committed.
        return kAccepted
    end

    local ok = core.apply_resolved_command(cmd, dp_get_store_path(env), dp_get_candidate_order_store_path(env))
    if not ok then
        -- Keep the command in place if saving failed.
        return kAccepted
    end

    -- Explicit pasted command ('词'码) may commit the added word once.
    -- Shorthand ('码) uses the word that is already on screen, so do not duplicate it.
    if cmd.action == "add" and not cmd.from_last_commit and cmd.text and cmd.text ~= "" then
        env.engine:commit_text(cmd.text)
    end
    context:clear()
    return kAccepted
end

-- ════════════════════════════════════════════════════════════════
-- 上屏通知（commit_notifier）全程只允许存在【一条】连接
--                                                     2026-09-26 修
--
-- ❗ 症状：'数字'编码 自造词取到重复文本（打「孙」「得」后 '2'swde 得到「得得」，
--          而正确答案是「孙得」）；'3' 会得到「得得得」。
--
-- 原因：本文件被【同时】挂成两个组件：
--         engine.processors: - lua_processor@*xmjd6/dynamic_phrase
--         engine.translators: - lua_translator@*xmjd6/dynamic_phrase
--       librime-lua（src/lua_gears.cc）的 LuaProcessor / LuaTranslator **构造函数**
--       都会调 raw_init()，raw_init() 又必然 pcall 模块的 init(env)，
--       所以 init 被调用【两次】（两个不同的 env 表）。
--       旧写法每个 env 各自 connect 一条、且从不 disconnect 旧的 → 两条都活着 →
--       每次上屏 remember_commit_text() 执行两遍 → commit_history = [孙,孙,得,得]。
--       recent_commit_text(hist, 2) 取末尾两个 → 「得得」。
--
-- 修法沿革：
--   首修（2026-09-26）：把连接句柄统一挂在 _G 状态表 dp_state 上，重连前先断开旧的
--     → 全程只有一条。这治好了「双挂载双记录」，但代价是把句柄做成了**全局唯一**，
--     于是引出下面这个更隐蔽的问题。
--   二修（2026-09-29）：改成「每个引擎各持一条」，引擎身份记在 Context 属性上。
--     详见下方 init / disconnect_commit_notifier 的注释。
--
-- 附带影响：repeat_history（i 前缀）与 text_transform（=wrap）读的是同一份
--       _G.__dynamic_phrase_state.commit_history，此前也被污染；
--       只因 repeat_history 自带 seen 去重、text_transform 只取末条，
--       肉眼看不出异常，所以这个 bug 是在自造词上先暴露的。
-- ════════════════════════════════════════════════════════════════
-- ★ 二修（2026-09-29）：每个引擎各持一条连接。
--   为什么不能用 Lua 侧对象当 key：
--     librime-lua 的 src/lib/lua_templates.h 里，LuaType<T*>::pushdata 与
--     LuaType<T&>::pushdata 每次都 lua_newuserdata，既不按指针做注册表缓存，
--     也没有 __eq —— 于是 env.engine.context **每访问一次就是一个全新 userdata**。
--     用 context 当表 key 永远命中不了（弱键表更是随取随回收）。
--   引擎身份只能在 C++ 侧按字符串记：Context:set_property / get_property
--     （同方案 text_transform.lua 已在用；全语料无人监听 property_update_notifier）。
--   首修那个「全局唯一句柄」做了什么坏事：
--     · 后建的会话（切窗口、程序重开）抢走连接 → 先建的会话静默停更；
--     · 会话销毁时 fini 又把全局句柄置空 → 之后谁都不记录，直到新建引擎。
--     「没部署、没操作，i 就失效」正是这个（真机 22:52 / 08:05 两次引擎重建
--     都掉进这个坑）。
local DP_WIRED_PROPERTY = "xmjd6_dynamic_phrase_wired"

local function disconnect_commit_notifier(env)
    -- 只断本 env 自己那条，并清掉**本引擎**的标记；绝不碰别的引擎。
    local connection = env and env.dynamic_phrase_commit_connection
    if not connection then
        -- 双挂载里被跳过的那一份：没接过，就什么都别做
        return
    end
    pcall(function() connection:disconnect() end)
    env.dynamic_phrase_commit_connection = nil
    if dp_state.commit_connection == connection then
        dp_state.commit_connection = nil
    end
    local context = env and env.engine and env.engine.context
    if context and type(context.set_property) == "function" then
        pcall(function() context:set_property(DP_WIRED_PROPERTY, "") end)
    end
end

local function init(env)
    local context = env and env.engine and env.engine.context
    if not context or not context.commit_notifier then
        return
    end

    local has_property_api = (type(context.get_property) == "function"
                              and type(context.set_property) == "function")

    if has_property_api then
        -- 幂等：同一引擎的 processor / translator 两次 init 只留一条连接。
        -- 标记存在 Context 上，跨「两层 userdata 包装」也能命中。
        local ok, wired = pcall(function()
            return context:get_property(DP_WIRED_PROPERTY)
        end)
        if ok and tostring(wired or "") == "1" then
            return
        end
    else
        -- 退化路径（无属性 API 的运行时）：沿用首修的「全局唯一句柄」，先断旧再连新。
        if dp_state.commit_connection then
            pcall(function() dp_state.commit_connection:disconnect() end)
            dp_state.commit_connection = nil
        end
    end

    local connection = context.commit_notifier:connect(function(ctx)
        local ok, committed = pcall(function() return ctx:get_commit_text() end)
        if ok then
            remember_commit_text(committed)
        end
    end)

    -- 连上了才落标记；否则一旦标记先落地而 connect 抛错，本引擎会永久跳过接线。
    if has_property_api and connection then
        pcall(function() context:set_property(DP_WIRED_PROPERTY, "1") end)
    end
    dp_state.commit_connection = connection
    env.dynamic_phrase_commit_connection = connection
end

local function fini(env)
    if not env then
        return
    end
    -- 只清自己这条；别的引擎那条不动。下一个引擎/会话自己会接上。
    disconnect_commit_notifier(env)
end


-- ════════════════════════════════════════════════════════════════
-- 导出：[0914] librime 取 func；processor / translator 用 @processor /
-- @translator 显式指定。未写 @ 时按入参类型分流。
-- ════════════════════════════════════════════════════════════════
local function dispatch(first, second, third)
    if type(first) == "string" then
        return translator(first, second, third)
    end
    return processor(first, second)
end

return { func = dispatch, init = init, fini = fini, core = M, translator = translator, processor = processor }
