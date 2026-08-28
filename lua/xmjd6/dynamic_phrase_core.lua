-- dynamic_phrase_core.lua
-- Pure Lua helpers for the xmjd6 dynamic personal phrase store.
-- Store format: one UTF-8 entry per line: text<TAB>code

local M = {}

-- Cache for indexed entries
local cache = {
    path = nil,
    mtime = nil,
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

local function get_file_mtime(path)
    local lfs_ok, lfs = pcall(require, "lfs")
    if lfs_ok and lfs.attributes then
        local ok, attr = pcall(lfs.attributes, path, "modification")
        if ok and attr then
            return attr
        end
    end
    -- Fallback: use file size + existence as a simple cache key
    local f = io.open(path, "r")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    return size or 0
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
    local mtime = get_file_mtime(path)

    if cache.path == path and cache.mtime == mtime and cache.entries then
        return cache.entries, cache.by_code, cache.by_root
    end

    -- Cache miss or stale - reload and rebuild indexes
    local entries = M.load_entries_uncached(path)
    local by_code, by_root = build_indexes(entries)
    cache.path = path
    cache.mtime = mtime
    cache.entries = entries
    cache.by_code = by_code
    cache.by_root = by_root

    return entries, by_code, by_root
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
        --   '词'编码;         → add text with code
        if arg == "" then
            return nil, "用法：'编码; 或 '词'编码; 或 'N'编码;"
        end

        -- Try: N'code  (multi-chunk add)
        local count, code = arg:match("^(%d+)'([^']+)$")
        if count ~= nil then
            code = trim(code)
            if code == "" then return nil, "编码不能为空" end
            return { action = "add", code = code, needs_last_commit = true, chunk_count = tonumber(count) or 1, execute_suffix = execute_suffix }
        end

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
        return { action = "add", code = code, needs_last_commit = true, execute_suffix = execute_suffix }
    end

    -- DEL syntax (separator is '):
    --   ''编码;           → delete all entries with this code
    --   ''词;             → delete all entries for this text
    --   ''词'编码;        → delete exact text+code pair
    --   ''N'编码;         → delete using last N commits as text
    if arg == "" then
        return nil, "用法：''编码; 或 ''词; 或 ''词'编码;"
    end

    -- Try: N'code  (multi-chunk del)
    local count, code = arg:match("^(%d+)'([^']+)$")
    if count ~= nil then
        code = trim(code)
        if code == "" then return nil, "编码不能为空" end
        return { action = "del", code = code, needs_last_commit = true, chunk_count = tonumber(count) or 1, execute_suffix = execute_suffix }
    end

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

    local ok_core, candidate_order_core = pcall(require, "xmjd6.candidate_order_core")
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

return M
