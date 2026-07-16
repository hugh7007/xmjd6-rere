-- 天行键 自造词核心模块
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-02

local M = {}
local codec = require("zzc.xmjd6_zzc_codec")
local store = require("zzc.xmjd6_zzc_store")

local char_parts
local char_parts_full_loaded = false
local char_parts_missing = {}
local pending_cache = {}
local pending_by_code = {}
local effective_projection_by_code = {}
local effective_by_code = {}
local pending_loaded = false
local pending_version = nil
local pending_version_check_second = nil
local write_file_atomic
local allow_cache = {}
local build_replace_snapshot
local rebuild_effective_projection_index
local update_effective_projection_for_code
local write_effective_state_file
local request_effective_state_write
local with_effective_state_batch
local runtime_ops_file
local effective_state_file
local pending_record_from_line
local runtime_reminder_seen_1000 = false
local runtime_reminder_pending_comment = nil
local zzc_reminder_shown_10000 = false
local zzc_reminder_last_time = 0
local zzc_effective_count_snapshot = nil

local function is_emoji_codepoint(cp)
    return (cp >= 0x1F000 and cp <= 0x1FAFF)
        or (cp >= 0x2600 and cp <= 0x27BF)
        or (cp >= 0x2300 and cp <= 0x23FF)
        or (cp >= 0x2B00 and cp <= 0x2BFF)
        or cp == 0x00A9
        or cp == 0x00AE
        or cp == 0x3030
        or cp == 0x303D
        or cp == 0x3297
        or cp == 0x3299
end

local function has_emoji_text(text)
    if type(text) ~= "string" or text == "" or not utf8 or not utf8.codes then return false end
    local has_emoji = false
    local ok = pcall(function()
        for _, cp in utf8.codes(text) do
            if is_emoji_codepoint(cp) then
                has_emoji = true
                break
            end
        end
    end)
    return ok and has_emoji
end

function M.candidate_type(cand)
    if not cand then return nil end
    local cand_type = cand.type
    if cand.get_genuine then
        local ok, genuine = pcall(function() return cand:get_genuine() end)
        if ok and genuine and genuine.type then cand_type = genuine.type end
    end
    return cand_type
end

function M.is_real_candidate(cand)
    local cand_type = M.candidate_type(cand)
    return cand
        and cand.text
        and cand.text ~= ""
        and cand.text:sub(1, 1) ~= "~"
        and not has_emoji_text(cand.text)
        and cand_type ~= "completion"
        and cand_type ~= "zzc_state"
        and cand_type ~= "zzc_make_word"
        and cand_type ~= "zzc_collect"
        and cand_type ~= "punct"
end

function M.is_collect_selectable_candidate(cand)
    return M.is_real_candidate(cand)
end

function M.is_completion_hint_candidate(cand)
    local cand_type = M.candidate_type(cand)
    local comment = cand and cand.comment or ""
    return cand_type == "completion"
        or (type(comment) == "string" and comment:match("^~[A-Za-z;']+$") ~= nil)
end

function M.candidate_visible_under_cover(cand, cover)
    if not M.is_collect_selectable_candidate(cand) then return false end
    if not cover or not cand or not cand.text then return true end
    return (not cover.keep_words or not cover.keep_words[cand.text])
        and (not cover.hide_words or not cover.hide_words[cand.text])
end

local function data_dir()
    if rime_api and rime_api.get_user_data_dir then
        return rime_api.get_user_data_dir()
    end
    return "."
end

local function join_path(base, name)
    if not base or base == "" then return name end
    return base .. "/" .. name
end

local function path(name)
    return join_path(data_dir(), name)
end

local function state_path(name)
    return path("zzc_state/" .. name)
end

local function legacy_state_path(name)
    return path("zzc/" .. name)
end

local function existing_state_path(name)
    local next_path = state_path(name)
    local f = io.open(next_path, "r")
    if f then
        f:close()
        return next_path
    end
    return legacy_state_path(name)
end

local function flag_exists(name)
    local f = io.open(path(name), "r")
    if not f then return false end
    f:close()
    return true
end

local function count_nonempty_lines(file_path)
    local f = io.open(file_path, "r")
    if not f then return 0 end
    local n = 0
    for line in f:lines() do
        if line and line ~= "" and line:sub(1, 1) ~= "#" then
            n = n + 1
        end
    end
    f:close()
    return n
end

local function runtime_ops_count()
    local f = io.open(runtime_ops_file(), "r")
    if not f then return 0 end
    local n = 0
    for line in f:lines() do
        local record = pending_record_from_line(line)
        if record and record.word and record.code then n = n + 1 end
    end
    f:close()
    return n
end

local function update_runtime_reminder()
    local n = runtime_ops_count()
    if n >= 3000 then
        runtime_reminder_pending_comment = "请尽快重新部署"
    elseif n >= 1000 and not runtime_reminder_seen_1000 then
        runtime_reminder_seen_1000 = true
        runtime_reminder_pending_comment = "建议重新部署"
    end
end

local function zzc_effective_count_at_load()
    if zzc_effective_count_snapshot == nil then
        zzc_effective_count_snapshot = count_nonempty_lines(effective_state_file())
    end
    return zzc_effective_count_snapshot
end

function M.take_reminder_comment()
    if runtime_reminder_pending_comment and runtime_reminder_pending_comment ~= "" then
        local comment = runtime_reminder_pending_comment
        runtime_reminder_pending_comment = nil
        return comment
    end
    local count = zzc_effective_count_at_load()
    if count < 10000 then return nil end
    local now = os.time()
    local comment
    if count >= 20000 then
        if (not zzc_reminder_shown_10000) or (now - zzc_reminder_last_time >= 10800) then
            comment = "zzc文件较大，请尽快电脑合并"
        end
    elseif count >= 15000 then
        if (not zzc_reminder_shown_10000) or (now - zzc_reminder_last_time >= 10800) then
            comment = "zzc文件较大，建议电脑合并"
        end
    elseif not zzc_reminder_shown_10000 then
        comment = "zzc文件较大，建议电脑合并"
    end
    if comment then
        zzc_reminder_shown_10000 = true
        zzc_reminder_last_time = now
    end
    return comment
end

local function hidden_stem()
    local k = 73
    local bytes = { 193, 182, 179, 173, 127 }
    local out = {}
    for i, v in ipairs(bytes) do
        out[i] = string.char(v - k)
    end
    return table.concat(out)
end

function M.allowed(env)
    local id = env and env.engine and env.engine.schema and env.engine.schema.schema_id or ""
    if allow_cache[id] ~= nil then return allow_cache[id] end
    local mark = hidden_stem()
    local ok = type(id) == "string" and id:sub(1, #mark) == mark
    allow_cache[id] = ok
    return ok
end

local function read_fields(line)
    return line:match("^([^\t]+)\t([^\t%s]+)")
end

local function utf8_chars(text)
    return codec.utf8_chars(text)
end

local function same_parts(a, b)
    return a and b and a.s == b.s and a.y == b.y and a.p == b.p
end

local function push_unique_part(bucket, entry)
    for _, current in ipairs(bucket) do
        if same_parts(current, entry) then return end
    end
    bucket[#bucket + 1] = entry
end

local function hint_matches(entry, hint)
    return codec.hint_matches(entry, hint)
end

local function collapse_options(options)
    return codec.collapse_options(options)
end

local function hint_list_for_word(word, code)
    local chars = utf8_chars(word)
    local n = #chars
    local len = #(code or "")
    local hints = {}
    if n == 1 then
        hints[1] = { code_prefix = code }
    elseif n == 2 then
        hints[1] = { s = code:sub(1, 1), y = code:sub(2, 2) }
        hints[2] = { s = code:sub(3, 3), y = code:sub(4, 4) }
        if len >= 5 then hints[1].p = code:sub(5, 5) end
        if len >= 6 then hints[2].p = code:sub(6, 6) end
    elseif n == 3 then
        hints[1] = { s = code:sub(1, 1) }
        hints[2] = { s = code:sub(2, 2) }
        hints[3] = { s = code:sub(3, 3) }
        if len >= 4 then hints[1].p = code:sub(4, 4) end
        if len >= 5 then hints[2].p = code:sub(5, 5) end
        if len >= 6 then hints[3].p = code:sub(6, 6) end
    elseif n >= 4 then
        hints[1] = { s = code:sub(1, 1) }
        hints[2] = { s = code:sub(2, 2) }
        hints[3] = { s = code:sub(3, 3) }
        hints[n] = { s = code:sub(4, 4) }
        if len >= 5 then hints[1].p = code:sub(5, 5) end
        if len >= 6 then hints[2].p = code:sub(6, 6) end
    end
    return hints
end

function M.hints_for_word_code(word, code)
    return hint_list_for_word(word, code)
end

function M.append_candidate_text(text, code_hint)
    if not text or text == "" then return nil, "empty_text" end
    local current_word = M.buffer_word() or ""
    local append_text_value = text
    if current_word ~= "" and #text > #current_word and text:sub(1, #current_word) == current_word then
        append_text_value = text:sub(#current_word + 1)
    end
    if append_text_value == "" then return current_word end
    local hints = code_hint and M.hints_for_word_code(append_text_value, code_hint) or nil
    local items, err = M.items_from_text(append_text_value, hints)
    if not items and err and tostring(err):match("^ambiguous_char:") then
        items = M.raw_items_from_text(append_text_value)
    end
    if not items then return nil, err end
    M.state_items = M.state_items or {}
    for _, item in ipairs(items) do
        M.state_items[#M.state_items + 1] = item
    end
    return append_text_value
end

local function add_char_part(text, s, y, p, code)
    local bucket = char_parts[text]
    if not bucket then
        bucket = {}
        char_parts[text] = bucket
    end
    push_unique_part(bucket, { s = s, y = y, p = p, code = code or (s .. y .. p) })
end

local function load_char_parts_from_tsv(target)
    local f = io.open(existing_state_path("char_parts.tsv"), "r")
    if not f then return false end
    local found = false
    local seen_target = false
    for line in f:lines() do
        local text, s, y, p, code = line:match("^([^\t]+)\t([^\t])\t([^\t])\t([^\t])\t([^\t%s]+)")
        if not text then
            text, s, y, p = line:match("^([^\t]+)\t([^\t])\t([^\t])\t([^\t])")
        end
        if text and s and y and p then
            if not target or text == target then
                add_char_part(text, s, y, p, code)
                found = true
                if target then seen_target = true end
            elseif target and seen_target then
                break
            end
        end
    end
    f:close()
    return true, found
end

local function load_char_parts_from_dict(target)
    local f = io.open(path("xmjd6.danzi.dict.yaml"), "r")
    if not f then return false, false end
    local found = false
    for line in f:lines() do
        if not line:match("^%s*#") then
            local text, code = read_fields(line)
            if text and code and (not target or text == target) and utf8.len(text) == 1 and #code >= 3 then
                add_char_part(text, code:sub(1, 1), code:sub(2, 2), code:sub(3, 3), code)
                found = true
            end
        end
    end
    f:close()
    return true, found
end

function M.load_char_parts(target)
    if not char_parts then char_parts = {} end
    if target and (char_parts[target] or char_parts_missing[target]) then return char_parts end
    if target and char_parts_full_loaded then return char_parts end
    if not target and char_parts_full_loaded then return char_parts end
    local load_target = target
    local opened, found
    if target then
        opened, found = load_char_parts_from_tsv(nil)
        if opened then
            char_parts_full_loaded = true
            found = char_parts[target] ~= nil
        end
    else
        opened, found = load_char_parts_from_tsv(load_target)
    end
    if not opened then
        opened, found = load_char_parts_from_dict(load_target)
    end
    if target then
        if not found then char_parts_missing[target] = true end
    else
        char_parts_full_loaded = true
    end
    return char_parts
end

function M.parts_for_char(ch, hint)
    local options = M.load_char_parts(ch)[ch]
    if not options or not options[1] then return nil, "missing_char:" .. tostring(ch) end
    if #options == 1 then return options[1] end

    local matched = {}
    if hint then
        for _, entry in ipairs(options) do
            if hint_matches(entry, hint) then matched[#matched + 1] = entry end
        end
        if #matched == 1 then return matched[1] end
        local collapsed = collapse_options(matched)
        if collapsed then return collapsed end
    end

    local collapsed = collapse_options(options)
    if collapsed then return collapsed end
    return nil, "ambiguous_char:" .. tostring(ch)
end

function M.items_from_text(text, hints)
    local items = {}
    for index, ch in ipairs(utf8_chars(text)) do
        local hint = nil
        if type(hints) == "table" then
            if hints.code_prefix or hints.s or hints.y or hints.p then
                hint = index == 1 and hints or nil
            else
                hint = hints[index]
            end
        elseif index == 1 then
            hint = hints
        end
        local part, err = M.parts_for_char(ch, hint)
        if not part then return nil, err end
        items[#items + 1] = { text = ch, parts = part }
    end
    return items
end

function M.raw_items_from_text(text)
    local items = {}
    for _, ch in ipairs(utf8_chars(text)) do
        items[#items + 1] = { text = ch, parts = nil }
    end
    return items
end

local code_at = codec.code_at

function M.code_choices_for_text(text, len, limit)
    limit = limit or 9
    len = tonumber(len)
    if not text or text == "" or not len then return nil, "bad_input" end
    local chars = utf8_chars(text)
    local n = #chars
    if n < 2 then return nil, "too_short" end
    if n == 2 and (len < 4 or len > 6) then return nil, "bad_length" end
    if n == 3 and (len < 3 or len > 6) then return nil, "bad_length" end
    if n >= 4 and (len < 4 or len > 6) then return nil, "bad_length" end

    local choices, seen = {}, {}
    local items = {}
    local function walk(index)
        if #choices >= limit then return end
        if index > n then
            local code = code_at(items, n):sub(1, len)
            if not seen[code] then
                seen[code] = true
                local frozen = {}
                for i, item in ipairs(items) do
                    frozen[i] = { text = item.text, parts = item.parts }
                end
                choices[#choices + 1] = { word = text, code = code, items = frozen }
            end
            return
        end
        local ch = chars[index]
        local options = M.load_char_parts(ch)[ch]
        if not options or not options[1] then return end
        for _, part in ipairs(options) do
            items[index] = { text = ch, parts = part }
            walk(index + 1)
            if #choices >= limit then break end
        end
        items[index] = nil
    end
    walk(1)
    if not choices[1] then return nil, "missing_or_ambiguous" end
    return choices
end

function M.code_for_items(items, len)
    return codec.code_for_items(items, len)
end

function M.word_from_items(items)
    return codec.word_from_items(items)
end

function M.serialize_items(items)
    return codec.serialize_items(items)
end

function M.deserialize_items(text)
    return codec.deserialize_items(text)
end

local function ops_file()
    return path("xmjd6.zzc.dict.yaml")
end

local function pending_file()
    return ops_file()
end

runtime_ops_file = function()
    return state_path("runtime_ops.tsv")
end

local function legacy_root_ops_file()
    return path("xmjd6.zzc.ops.tsv")
end

local function legacy_ops_file()
    return existing_state_path("ops.tsv")
end

local function legacy_pending_file()
    return existing_state_path("pending.tsv")
end

effective_state_file = function()
    return state_path("effective_state.tsv")
end

local function pending_version_file()
    return state_path("cache_version.tsv")
end

local function legacy_pending_version_file()
    return existing_state_path("cache_version.txt")
end

local function runtime_ops_append_stamp_file()
    return state_path("runtime_ops_appended.tsv")
end

local function runtime_exact_file()
    return state_path("runtime_exact.tsv")
end

local function readable_runtime_exact_file()
    return existing_state_path("runtime_exact.tsv")
end

local function reset_marker_file()
    return existing_state_path("zzc_reset.tsv")
end

local function reset_seen_file()
    return state_path("zzc_reset_seen.tsv")
end

local function read_first_line(file_path)
    local f = io.open(file_path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    return line
end

local function reset_marker_from_file(file_path)
    local f = io.open(file_path, "r")
    if not f then return nil end
    local marker = {}
    for line in f:lines() do
        local key, value = line:match("^([^\t]+)\t(.+)$")
        if key and value then
            marker[key] = value
        end
    end
    f:close()
    if marker.version ~= "2" or marker.schema ~= "xmjd6" or marker.mode ~= "full_reset" then
        return nil
    end
    local token = marker.reset_token or ""
    if not token:match("^[0-9a-fA-F]+$") then return nil end
    marker.reset_token = token:lower()
    return marker
end

local function file_has_content(file_path)
    local f = io.open(file_path, "r")
    if not f then return false end
    local has_content = false
    for line in f:lines() do
        if line:match("%S") then
            has_content = true
            break
        end
    end
    f:close()
    return has_content
end

local function ops_has_body_record()
    local f = io.open(pending_file(), "r")
    if not f then return false end
    for line in f:lines() do
        if pending_record_from_line(line) then
            f:close()
            return true
        end
    end
    f:close()
    return false
end

local function has_local_resettable_zzc_state()
    return ops_has_body_record()
        or file_has_content(runtime_ops_file())
        or file_has_content(readable_runtime_exact_file())
        or file_has_content(effective_state_file())
        or file_has_content(runtime_ops_append_stamp_file())
end

local function runtime_ops_signature()
    local f = io.open(runtime_ops_file(), "r")
    if not f then return "" end
    local hash = 2166136261
    for line in f:lines() do
        local text = line .. "\n"
        for i = 1, #text do
            hash = (hash * 16777619 + text:byte(i)) % 4294967296
        end
    end
    f:close()
    return string.format("%08x", hash)
end

local function new_tx()
    return os.date("%Y%m%d%H%M%S") .. string.format("%03d", math.floor((os.clock() * 1000) % 1000))
end

pending_record_from_line = function(line)
    return store.record_from_line(line)
end

local function pending_line_from_record(record)
    return store.pending_line(record, new_tx)
end

local function runtime_line_from_record(record)
    return store.runtime_line(record, new_tx)
end

local function ops_header()
    return table.concat({
        "# Rime dictionary",
        "# encoding: utf-8",
        "---",
        "name: xmjd6.zzc",
        "version: \"2026-06-20\"",
        "sort: by_weight",
        "use_preset_vocabulary: false",
        "columns:",
        "  - text",
        "  - code",
        "..."
    }, "\n") .. "\n"
end

local function ensure_ops_file()
    local f = io.open(pending_file(), "r")
    if f then
        f:close()
        return
    end
    f = io.open(pending_file(), "w")
    if not f then return end
    f:write(ops_header())
    f:close()
end

local function ensure_runtime_ops_file()
    local f = io.open(runtime_ops_file(), "r")
    if f then
        f:close()
        return
    end
    f = io.open(runtime_ops_file(), "w")
    if not f then return end
    f:close()
end

local function read_pending_version()
    local f = io.open(pending_version_file(), "r")
    if f then
        local value = ""
        for line in f:lines() do
            local key, item = line:match("^([^\t]+)\t(.+)$")
            if key == "cache_token" then
                value = item or ""
                break
            end
        end
        f:close()
        return value
    end
    return read_first_line(legacy_pending_version_file()) or ""
end

local function write_pending_version()
    local value = new_tx()
    local ok, err = write_file_atomic(pending_version_file(), { "cache_token\t" .. value })
    if not ok then return nil, err end
    pending_version = read_pending_version()
    pending_version_check_second = os.time()
    return value
end

local function load_pending_cache()
    if pending_loaded then return pending_cache end
    pending_cache = {}
    pending_by_code = {}
    effective_projection_by_code = {}
    for _, file_path in ipairs({ ops_file(), runtime_ops_file() }) do
        local is_runtime = file_path == runtime_ops_file()
        local f = io.open(file_path, "r")
        if f then
            for line in f:lines() do
                local record = pending_record_from_line(line)
                if record and record.code and record.word then
                    record.runtime = is_runtime or nil
                    pending_cache[#pending_cache + 1] = record
                    local bucket = pending_by_code[record.code]
                    if not bucket then
                        bucket = {}
                        pending_by_code[record.code] = bucket
                    end
                    bucket[#bucket + 1] = record
                end
            end
            f:close()
        end
    end
    pending_loaded = true
    pending_version = read_pending_version()
    pending_version_check_second = os.time()
    if rebuild_effective_projection_index then rebuild_effective_projection_index() end
    return pending_cache
end

local function reload_pending_cache()
    pending_loaded = false
    pending_cache = {}
    pending_by_code = {}
    effective_projection_by_code = {}
    pending_version_check_second = nil
    return load_pending_cache()
end

local function load_pending_cache_current()
    if pending_loaded then
        local now = os.time()
        if pending_version_check_second == now then
            return pending_cache
        end
        pending_version_check_second = now
        if read_pending_version() == pending_version then
            return pending_cache
        end
    end
    return reload_pending_cache()
end

local function pending_records_for_code(code)
    load_pending_cache_current()
    return pending_by_code[code] or {}
end

local function append_pending_cache(record)
    if not pending_loaded then return end
    local cached = {
        mark = record.mark or "+",
        op = record.op,
        append = record.append and true or nil,
        restore = record.restore and true or nil,
        word = record.word,
        code = record.code,
        tx = record.tx,
        runtime = record.runtime and true or nil,
    }
    pending_cache[#pending_cache + 1] = cached
    local bucket = pending_by_code[cached.code]
    if not bucket then
        bucket = {}
        pending_by_code[cached.code] = bucket
    end
    bucket[#bucket + 1] = cached
    if update_effective_projection_for_code then update_effective_projection_for_code(cached.code) end
end

local function rewrite_ops_records(records)
    return with_effective_state_batch(function()
    local lines = {}
    local header = ops_header()
    for line in header:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    for _, record in ipairs(records or {}) do
        lines[#lines + 1] = pending_line_from_record(record)
    end
    local ok, err = write_file_atomic(pending_file(), lines)
    if not ok then return nil, err end
    pending_cache = records or {}
    pending_by_code = {}
    effective_projection_by_code = {}
    for _, record in ipairs(pending_cache) do
        local bucket = pending_by_code[record.code]
        if not bucket then
            bucket = {}
            pending_by_code[record.code] = bucket
        end
        bucket[#bucket + 1] = record
    end
    pending_loaded = true
    if rebuild_effective_projection_index then rebuild_effective_projection_index() end
    write_pending_version()
    return true
    end)
end

local function rewrite_runtime_ops_records(records)
    return with_effective_state_batch(function()
    local lines = {}
    for _, record in ipairs(records or {}) do
        local runtime_record = {
            mark = record.mark,
            append = record.append,
            word = record.word,
            code = record.code,
            tx = record.tx,
            runtime = true,
        }
        lines[#lines + 1] = runtime_line_from_record(runtime_record)
    end
    local ok, err = write_file_atomic(runtime_ops_file(), lines)
    if not ok then return nil, err end
    local legacy = {}
    local f = io.open(ops_file(), "r")
    if f then
        for line in f:lines() do
            local record = pending_record_from_line(line)
            if record and record.code and record.word then legacy[#legacy + 1] = record end
        end
        f:close()
    end
    local merged = {}
    for _, record in ipairs(legacy) do merged[#merged + 1] = record end
    for _, record in ipairs(records or {}) do
        record.runtime = true
        merged[#merged + 1] = record
    end
    pending_cache = merged
    pending_by_code = {}
    effective_projection_by_code = {}
    for _, record in ipairs(pending_cache) do
        local bucket = pending_by_code[record.code]
        if not bucket then
            bucket = {}
            pending_by_code[record.code] = bucket
        end
        bucket[#bucket + 1] = record
    end
    pending_loaded = true
    if rebuild_effective_projection_index then rebuild_effective_projection_index() end
    write_pending_version()
    return true
    end)
end

local function append_ops_records_to_pending(records)
    return with_effective_state_batch(function()
        ensure_ops_file()
        local f = io.open(pending_file(), "a")
        if not f then return nil, "ops_open_failed" end
        for _, record in ipairs(records or {}) do
            f:write(pending_line_from_record(record), "\n")
        end
        f:close()
        write_pending_version()
        return true
    end)
end

local function compact_pending_records(records)
    local latest = {}
    local latest_order_tx_by_code = {}
    for _, record in ipairs(records or {}) do
        if record and record.word and record.code then
            if record.mark == "^" and record.tx and record.tx ~= "" then
                latest_order_tx_by_code[record.code] = record.tx
            else
                latest[record.word .. "\t" .. record.code] = record
            end
        end
    end
    local out = {}
    for _, record in ipairs(records or {}) do
        local key = record and record.word and record.code and (record.word .. "\t" .. record.code) or nil
        if key and record.mark ~= "^" and latest[key] == record then
            out[#out + 1] = record
        end
    end
    local order_seen = {}
    for _, record in ipairs(records or {}) do
        if record and record.mark == "^" and latest_order_tx_by_code[record.code] == record.tx then
            local key = record.word .. "\t" .. record.code
            local current = latest[key]
            if current and current.mark ~= "!" and not order_seen[key] then
                out[#out + 1] = record
                order_seen[key] = true
            end
        end
    end
    return out
end

local function flush_runtime_ops_to_pending()
    ensure_ops_file()
    ensure_runtime_ops_file()
    local records = load_pending_cache_current()
    local runtime_signature = runtime_ops_signature()
    local runtime_records = {}
    for _, record in ipairs(records or {}) do
        if record.runtime then
            runtime_records[#runtime_records + 1] = {
                mark = record.mark,
                op = record.op,
                append = record.append,
                restore = record.restore,
                word = record.word,
                code = record.code,
                tx = record.tx,
            }
        end
    end
    if not runtime_records[1] then return true, false end
    local appended_signature = read_first_line(runtime_ops_append_stamp_file()) or ""
    if appended_signature ~= runtime_signature then
        local ok, err = append_ops_records_to_pending(runtime_records)
        if not ok then return nil, err end
        write_file_atomic(runtime_ops_append_stamp_file(), { runtime_signature })
    end
    local ok, err
    ok, err = write_file_atomic(runtime_ops_file(), {})
    if not ok then return nil, err end
    write_file_atomic(runtime_exact_file(), {})
    write_file_atomic(effective_state_file(), {})
    pending_loaded = false
    load_pending_cache_current()
    return true, true
end

local function cleanup_appended_runtime_ops()
    ensure_runtime_ops_file()
    local records = load_pending_cache_current()
    local runtime_signature = runtime_ops_signature()
    local runtime_records = {}
    for _, record in ipairs(records or {}) do
        if record.runtime then
            runtime_records[#runtime_records + 1] = record
        end
    end
    if not runtime_records[1] then return true, false end
    local appended_signature = read_first_line(runtime_ops_append_stamp_file()) or ""
    if appended_signature ~= runtime_signature then
        return true, false
    end
    local ok, err = write_file_atomic(runtime_ops_file(), {})
    if not ok then return nil, err end
    write_file_atomic(runtime_exact_file(), {})
    write_file_atomic(effective_state_file(), {})
    pending_loaded = false
    load_pending_cache_current()
    return true, true
end

local function apply_reset_marker()
    local marker = reset_marker_from_file(reset_marker_file())
    if not marker then return true, false end
    local seen = reset_marker_from_file(reset_seen_file())
    if seen and seen.reset_token == marker.reset_token then
        return true, false
    end
    local header_lines = {}
    for line in ops_header():gmatch("([^\n]*)\n") do
        header_lines[#header_lines + 1] = line
    end
    local ok, err = write_file_atomic(pending_file(), header_lines)
    if not ok then return nil, err end
    for _, file_path in ipairs({
        runtime_ops_file(),
        runtime_exact_file(),
        effective_state_file(),
        runtime_ops_append_stamp_file(),
    }) do
        ok, err = write_file_atomic(file_path, {})
        if not ok then return nil, err end
    end
    ok, err = write_file_atomic(reset_seen_file(), {
        "version\t2",
        "schema\txmjd6",
        "mode\tfull_reset",
        "reset_token\t" .. marker.reset_token,
    })
    if not ok then return nil, err end
    ok, err = write_pending_version()
    if not ok then return nil, err end
    pending_loaded = false
    pending_cache = {}
    pending_by_code = {}
    effective_projection_by_code = {}
    effective_by_code = {}
    load_pending_cache_current()
    return true, true
end

local function append_ops_record(record)
    ensure_runtime_ops_file()
    record.runtime = true
    local f = io.open(runtime_ops_file(), "a")
    if not f then return nil, "ops_open_failed" end
    f:write(runtime_line_from_record(record), "\n")
    f:close()
    write_pending_version()
    append_pending_cache(record)
    update_runtime_reminder()
    return true
end

local function append_ops_records(records)
    return with_effective_state_batch(function()
        ensure_runtime_ops_file()
        local f = io.open(runtime_ops_file(), "a")
        if not f then return nil, "ops_open_failed" end
        local tx = new_tx()
        for _, record in ipairs(records or {}) do
            record.tx = record.tx or tx
            record.runtime = true
            f:write(runtime_line_from_record(record), "\n")
        end
        f:close()
        write_pending_version()
        for _, record in ipairs(records or {}) do
            append_pending_cache(record)
        end
        update_runtime_reminder()
        return true
    end)
end

write_effective_state_file = function()
    local lines = {}
    effective_by_code = {}
    for code, cover in pairs(effective_projection_by_code or {}) do
        local snapshot = store.effective_state_snapshot and store.effective_state_snapshot(code, cover) or nil
        local effective = snapshot and snapshot.effective or { rows = {}, append_rows = {}, keep_words = {}, hide_words = {}, restore_rows = {} }
        for _, line in ipairs((snapshot and snapshot.lines) or {}) do
            lines[#lines + 1] = line
        end
        if effective.rows[1] or effective.append_rows[1] or next(effective.hide_words) then
            effective_by_code[code] = effective
        end
    end
    table.sort(lines)
    return write_file_atomic(effective_state_file(), lines)
end

local effective_state_write_depth = 0
local effective_state_write_pending = false

request_effective_state_write = function()
    if not write_effective_state_file then return end
    if effective_state_write_depth > 0 then
        effective_state_write_pending = true
        return
    end
    write_effective_state_file()
end

with_effective_state_batch = function(fn)
    effective_state_write_depth = effective_state_write_depth + 1
    local results = { pcall(fn) }
    effective_state_write_depth = effective_state_write_depth - 1
    local ok = results[1]
    if ok and effective_state_write_depth == 0 and effective_state_write_pending then
        effective_state_write_pending = false
        request_effective_state_write()
    end
    if not ok then error(results[2]) end
    return table.unpack(results, 2, results.n or #results)
end

local function word_valid_at_code(pending, word, code)
    return store.word_valid_at_code(pending, word, code)
end

local function build_effective_projection(input, pending, opts)
    return store.build_effective_projection(input, pending, opts)
end

update_effective_projection_for_code = function(code)
    if not code or code == "" then return end
    effective_projection_by_code[code] = build_effective_projection(code, pending_by_code[code] or {})
    request_effective_state_write()
end

rebuild_effective_projection_index = function()
    with_effective_state_batch(function()
        effective_projection_by_code = {}
        for code in pairs(pending_by_code) do
            if code and code ~= "" then
                effective_projection_by_code[code] = build_effective_projection(code, pending_by_code[code] or {})
            end
        end
        request_effective_state_write()
    end)
end

local function enqueue_snapshot(snapshot)
    local first_code, first_word
    local ok, err = append_ops_records(snapshot or {})
    if not ok then
        return nil, err
    end
    for _, record in ipairs(snapshot or {}) do
        if (record.mark == "+" or record.mark == "-") and not record.append then
            if not first_code and record.mark == "+" then
                first_code = record.code
                first_word = record.word
            end
        end
    end
    return first_code, first_word
end

function M.enqueue_pending(items, len, probe_first)
    local code, err = M.code_for_items(items, len)
    if not code then return nil, err end
    return M.save_word(items, len, probe_first)
end

function M.enqueue_replace(items, target_code, replaced_word, probe_first)
    if not target_code or target_code == "" then return nil, "missing_target_code" end
    return M.save_word_at_code(items, target_code, replaced_word, probe_first)
end

function M.move_word_to_code(word, source_code, target_code, probe_first, replaced_word)
    if not word or word == "" then return nil, "missing_word" end
    if not source_code or source_code == "" then return nil, "missing_source_code" end
    if not target_code or target_code == "" then return nil, "missing_target_code" end
    local snapshot = build_replace_snapshot(word, target_code, replaced_word, probe_first, "move")
    snapshot[#snapshot + 1] = { op = "delete", mark = "!", word = word, code = source_code }
    local saved_code, saved_word = enqueue_snapshot(snapshot)
    return saved_code, saved_word
end

function M.undo_last_tx()
    local records = load_pending_cache_current()
    local last_tx
    for i = #records, 1, -1 do
        if records[i].runtime and records[i].tx and records[i].tx ~= "" then
            last_tx = records[i].tx
            break
        end
    end
    if not last_tx then return nil, "missing_tx" end
    local kept = {}
    for _, record in ipairs(records) do
        if record.runtime and record.tx ~= last_tx then kept[#kept + 1] = record end
    end
    local ok, err = rewrite_runtime_ops_records(kept)
    if not ok then return nil, err end
    return true, last_tx
end

function M.undo_all_pending()
    local had_records = false
    for _, record in ipairs(load_pending_cache_current() or {}) do
        if record and record.code and record.word then
            had_records = true
            break
        end
    end
    local header_lines = {}
    for line in ops_header():gmatch("([^\n]*)\n") do
        header_lines[#header_lines + 1] = line
    end
    local ok, err = write_file_atomic(pending_file(), header_lines)
    if not ok then return nil, err end
    ok, err = write_file_atomic(runtime_ops_file(), {})
    if not ok then return nil, err end
    for _, file_path in ipairs({ legacy_root_ops_file(), legacy_ops_file(), legacy_pending_file() }) do
        local f = io.open(file_path, "r")
        if f then
            f:close()
            ok, err = write_file_atomic(file_path, {})
            if not ok then return nil, err end
        end
    end
    pending_cache = {}
    pending_by_code = {}
    effective_projection_by_code = {}
    effective_by_code = {}
    pending_loaded = true
    write_pending_version()
    request_effective_state_write()
    return true, had_records
end

function M.delete_word_at_code(word, code)
    if not word or word == "" then return nil, "missing_word" end
    if not code or code == "" then return nil, "missing_code" end
    local record = { op = "delete", mark = "!", word = word, code = code, tx = new_tx() }
    local ok, err = append_ops_record(record)
    if not ok then return nil, err end
    return true, record.tx
end

function M.flush_runtime_ops()
    return flush_runtime_ops_to_pending()
end

function M.cleanup_appended_runtime_ops()
    return cleanup_appended_runtime_ops()
end

function M.apply_reset_marker()
    return apply_reset_marker()
end

function M.maybe_flush_after_deploy(env)
    local ok, changed_or_err = apply_reset_marker()
    if not ok then return nil, changed_or_err end
    if changed_or_err == true then return true, true end
    return cleanup_appended_runtime_ops()
end

function M.reorder_words_at_code(words, code)
    if not words or not words[1] then return nil, "missing_words" end
    if not code or code == "" then return nil, "missing_code" end
    local tx = new_tx()
    local records = {}
    local seen = {}
    local pending = load_pending_cache_current()
    for _, word in ipairs(words or {}) do
        if word and word ~= "" and not seen[word] and word_valid_at_code(pending, word, code) then
            seen[word] = true
            records[#records + 1] = { op = "order", mark = "^", word = word, code = code, tx = tx }
        end
    end
    if not records[1] then return nil, "missing_words" end
    local ok, err = append_ops_records(records)
    if not ok then return nil, err end
    return true, tx
end

function M.buffer_word()
    return M.word_from_items(M.state_items or {})
end

function M.set_state_items(items)
    M.state_items = items
end

function M.set_current_stage(stage)
    M._current_stage = stage
end

function M.current_stage()
    return M._current_stage or "off"
end

write_file_atomic = function(file_path, lines)
    local tmp = file_path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        return nil, "open_failed:" .. file_path
    end
    for _, line in ipairs(lines) do f:write(line, "\n") end
    f:close()
    local renamed = os.rename(tmp, file_path)
    if renamed then return true end
    os.remove(file_path)
    renamed = os.rename(tmp, file_path)
    if not renamed then
        os.remove(tmp)
        return nil, "rename_failed:" .. file_path
    end
    return true
end

local function append_next_code(word, code)
    if #code >= 6 then return nil, "max_code" end
    local chars = utf8_chars(word)
    local n = #chars
    local len = #code
    local target_index
    local hint = {}
    if n == 2 then
        if len == 4 then
            target_index = 1
            hint = { s = code:sub(1, 1), y = code:sub(2, 2) }
        elseif len == 5 then
            target_index = 2
            hint = { s = code:sub(3, 3), y = code:sub(4, 4) }
        end
    elseif n == 3 then
        if len >= 3 and len <= 5 then
            target_index = len - 2
            hint = { s = code:sub(target_index, target_index) }
        end
    elseif n >= 4 then
        if len == 4 then
            target_index = 1
            hint = { s = code:sub(1, 1) }
        elseif len == 5 then
            target_index = 2
            hint = { s = code:sub(2, 2) }
        end
    end
    if not target_index or not chars[target_index] then return nil, "no_longer_code" end
    local options = M.load_char_parts(chars[target_index])[chars[target_index]]
    if not options or not options[1] then return nil, "missing_char:" .. tostring(chars[target_index]) end
    local p
    for _, entry in ipairs(options) do
        if hint_matches(entry, hint) then
            if not p then p = entry.p elseif p ~= entry.p then return nil, "ambiguous_char:" .. tostring(chars[target_index]) end
        end
    end
    if not p then return nil, "missing_char:" .. tostring(chars[target_index]) end
    return code .. p
end

local function build_direct_snapshot(word, code, op)
    return { { op = op or "make", mark = "+", word = word, code = code } }
end

function M.append_word_at_code(items, target_code)
    if not target_code or target_code == "" then return nil, "missing_target_code" end
    local word = M.word_from_items(items)
    if not word or word == "" then return nil, "missing_word" end
    local snapshot = { { op = "append", mark = "+", append = true, word = word, code = target_code } }
    local _, err = enqueue_snapshot(snapshot)
    if err then
        return nil, err
    end
    return target_code, word
end

function M.restore_rows_for_input(input)
    if not input or input == "" then return nil end
    load_pending_cache_current()
    local effective = effective_by_code[input]
    local rows = effective and effective.restore_rows or nil
    if not (rows and rows[1]) then return nil end
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = { word = row.word, code = row.code, source = row.source or "zzc_restore" }
    end
    return out
end

function M.restore_word_at_code(word, code)
    if not word or word == "" then return nil, "missing_word" end
    if not code or code == "" then return nil, "missing_code" end
    local record = { op = "restore", mark = "+", restore = true, word = word, code = code, tx = new_tx() }
    local ok, err = append_ops_record(record)
    if not ok then return nil, err end
    return true, record.tx
end

build_replace_snapshot = function(word, code, replaced_word, probe_first, op)
    local snapshot = build_direct_snapshot(word, code, op)
    if (not replaced_word or replaced_word == "") and probe_first then
        local ok, probed = pcall(function() return probe_first(code) end)
        if ok and probed and probed ~= "" then replaced_word = probed end
    end
    local displaced_word = replaced_word
    local displaced_code = code
    local visiting = {}
    while displaced_word and displaced_word ~= "" and displaced_word ~= word and not visiting[displaced_word] do
        visiting[displaced_word] = true
        local next_code = append_next_code(displaced_word, displaced_code)
        if next_code then
            snapshot[#snapshot + 1] = { op = "move", mark = "-", word = displaced_word, code = next_code }
            snapshot[#snapshot + 1] = { op = "delete", mark = "!", word = displaced_word, code = displaced_code }
            if #next_code >= 6 then break end
            local next_word = nil
            if probe_first then
                local ok, probed = pcall(function() return probe_first(next_code) end)
                if ok and probed and probed ~= "" then next_word = probed end
            end
            if not next_word or next_word == displaced_word or next_word == word then break end
            displaced_word = next_word
            displaced_code = next_code
        else
            break
        end
    end
    return snapshot
end

local function save_word_to_code(items, code, replaced_word, probe_first)
    local word = M.word_from_items(items)
    if not code then
        return nil, "missing_code"
    end
    local op = replaced_word and replaced_word ~= "" and "replace" or "make"
    local snapshot = build_replace_snapshot(word, code, replaced_word, probe_first, op)
    local saved_code, err = enqueue_snapshot(snapshot)
    if not saved_code then
        return nil, err
    end
    return code, word
end

function M.save_word(items, len, probe_first)
    local code, err = M.code_for_items(items, len)
    if not code then
        return nil, err
    end
    return save_word_to_code(items, code, nil, probe_first)
end

function M.save_word_at_code(items, code, replaced_word, probe_first)
    return save_word_to_code(items, code, replaced_word, probe_first)
end

function M.zzc_cover_for_input(input, opts)
    if not input or input == "" then return nil end
    opts = opts or {}
    if opts.ignore_order then
        return build_effective_projection(input, pending_records_for_code(input), opts)
    end
    load_pending_cache_current()
    return effective_by_code[input]
end

function M.zzc_order_for_input(input)
    if not input or input == "" then return nil end
    load_pending_cache_current()
    local cover = effective_by_code[input]
    if cover and cover.has_order then return cover end
    return nil
end

function M.zzc_completion_rows_for_prefix(prefix, limit)
    if not prefix or prefix == "" then return nil end
    load_pending_cache_current()
    local rows, seen = {}, {}
    limit = limit or 30
    for code, pending in pairs(pending_by_code) do
        if code ~= prefix and code:sub(1, #prefix) == prefix then
            local cover = effective_by_code[code] or effective_projection_by_code[code] or build_effective_projection(code, pending)
            if cover then
                local function push(row)
                    if row and row.word and row.word ~= "" and row.code and not seen[row.word] then
                        rows[#rows + 1] = { word = row.word, code = row.code, source = row.source or "zzc_completion" }
                        seen[row.word] = true
                    end
                end
                for _, row in ipairs(cover.rows or {}) do
                    push(row)
                end
                for _, row in ipairs(cover.append_rows or {}) do
                    push(row)
                end
            end
        end
    end
    table.sort(rows, function(left, right)
        if #left.code ~= #right.code then return #left.code < #right.code end
        if left.code ~= right.code then return left.code < right.code end
        return left.word < right.word
    end)
    if not rows[1] then return nil end
    return rows
end

function M.cover_for_probe(input, opts)
    return M.zzc_cover_for_input(input, opts)
end

return M
