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
    order_mtime = nil,
    data = nil,
}

local function clear_cache()
    cache.order_path = nil
    cache.order_mtime = nil
    cache.data = nil
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

local function file_mtime(path)
    local lfs_ok, lfs = pcall(require, "lfs")
    if lfs_ok and lfs.attributes then
        local ok, attr = pcall(lfs.attributes, path, "modification")
        if ok and attr then return attr end
    end
    local f = io.open(path, "r")
    if not f then return 0 end
    local size = f:seek("end") or 0
    f:close()
    return size
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
    local ok, dynamic_core = pcall(require, "xmjd6.dynamic_phrase_core")
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

function M.load_occupied_codes_for_candidates(base_dir, candidate_codes, exclude_pairs)
    local target_codes = normalize_target_codes(candidate_codes)
    local occupied = {}
    for _, name in ipairs(M.occupied_dict_files) do
        load_occupied_from_table(join_path(base_dir, name), occupied, exclude_pairs, target_codes)
    end
    merge_occupied_map(occupied, load_dynamic_occupied(base_dir, target_codes, exclude_pairs))
    return occupied
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
    }
    for _, rec in ipairs(records) do
        append_index(data.by_target, rec.target_code, rec)
        append_index(data.by_old, rec.old_code, rec)
        if rec.new_code and rec.new_code ~= "" then
            append_index(data.by_new, rec.new_code, rec)
        end
    end
    return data
end

function M.load(filename)
    local base_dir = M.user_data_dir()
    local order_path = M.store_path(filename or M.default_filename)
    local order_mtime = file_mtime(order_path)

    if cache.data and cache.order_path == order_path and cache.order_mtime == order_mtime then
        return cache.data
    end

    local records, errors = load_orders_uncached(order_path)
    local data = build_data(records, errors)

    cache.order_path = order_path
    cache.order_mtime = order_mtime
    cache.data = data
    return data
end

local function records_needing_new_code(data, input)
    local out = {}
    if not data or type(input) ~= "string" or input == "" then return out end
    for _, rec in ipairs(data.records or {}) do
        if record_needs_new_code(rec) and not rec.new_code
            and input:sub(1, #rec.target_code) == rec.target_code then
            out[#out + 1] = rec
        end
    end
    return out
end

function M.ensure_new_codes_for_input(data, input)
    local records = records_needing_new_code(data, input)
    if #records == 0 then return end
    local base_dir = M.user_data_dir()
    local char_codes = load_char_codes_uncached(base_dir, collect_displaced_chars(records))
    local target_codes = prepare_candidate_codes(records, char_codes)
    if not target_codes then return end
    local occupied = M.load_occupied_codes_for_candidates(base_dir, target_codes, build_exclude_pairs(data.records or {}))
    add_order_occupancy(occupied, data.records or {}, target_codes)
    fill_new_codes(records, char_codes, data, occupied)
end

function M.records_for_input(input, filename)
    local data = M.load(filename)
    local new_records = {}
    for _, rec in ipairs(data.by_new[input] or {}) do
        new_records[#new_records + 1] = rec
    end
    for _, rec in ipairs(data.records or {}) do
        if rec.new_code and #input < #rec.new_code
            and rec.new_code:sub(1, #input) == input
            and input ~= rec.target_code then
            new_records[#new_records + 1] = rec
        end
    end
    return data.by_target[input] or {}, new_records, data
end

function M.has_rules_for_input(data, input)
    if not data or type(input) ~= "string" or input == "" then return false end
    return data.by_target[input] ~= nil or data.by_old[input] ~= nil
end

function M.has_code_prefix(prefix, filename)
    if type(prefix) ~= "string" or prefix == "" then return false end
    if not is_code(prefix) then return false end

    local data = M.load(filename)
    for _, rec in ipairs(data.records or {}) do
        if rec.target_code and #prefix <= #rec.target_code
            and rec.target_code:sub(1, #prefix) == prefix then
            return true
        end
        if rec.old_code and #prefix <= #rec.old_code
            and rec.old_code:sub(1, #prefix) == prefix then
            return true
        end
        if rec.new_code and #prefix <= #rec.new_code
            and rec.new_code:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
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
    merge_char_codes(char_codes, load_char_codes_uncached(base_dir, wanted))
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
    if record_needs_new_code(current_rec) and new_code == "" then
        local wanted = {}
        for _, ch in ipairs(split_chars(displaced)) do
            wanted[ch] = true
        end
        local base_dir = M.user_data_dir()
        local char_codes = load_char_codes_uncached(base_dir, wanted)
        current_rec.full_code = M.phrase_full_code(displaced, target_code, char_codes)
        current_rec._candidate_new_codes = M.candidate_new_codes(target_code, current_rec.full_code)
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
            new_code = M.choose_candidate_code(
                current_rec._candidate_new_codes,
                occupied,
                { [promoted] = true, [displaced] = true }
            ) or ""
        end
        current_rec.new_code = new_code
    end

    local newline = format_record_line(promoted, old_code, displaced, target_code, new_code)

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
        if current_rec.same_code then
            for _, line in ipairs(chain_lines or {}) do
                if not line_exists(kept_lines, line) and line ~= newline then
                    wf:write(line, "\n")
                    kept_lines[#kept_lines + 1] = line
                end
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

return M
