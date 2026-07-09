-- 天行键 自造词存储模块
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-02

local M = {}

local function new_tx()
    return os.date("%Y%m%d%H%M%S") .. string.format("%03d", math.floor((os.clock() * 1000) % 1000))
end

function M.record_from_line(line)
    local tx, op, word, code, mark_token = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t%s]+)\t([+%-!%^]a?r?)$")
    if tx and op and word and code and mark_token then
        local mark = mark_token:sub(1, 1)
        return { tx = tx, op = op, mark = mark, append = mark_token == "+a", restore = mark_token == "+r" or op == "restore", word = word, code = code, runtime = true }
    end
    local yaml_line = line
    if yaml_line:match("^%s*#") or yaml_line:match("^%s*$") or yaml_line:match("^%s*%.%.%.%s*$") or yaml_line:match("^%s*%-%-%-%s*$") then
        return nil
    elseif yaml_line:match("^%s*[%w_]+:") or yaml_line:match("^%s*%- ") then
        return nil
    end
    local yaml_word, yaml_code, yaml_mark_token, yaml_tx = yaml_line:match("^([^\t#]+)\t([^%s#]+)%s*#%s*([+%-!%^]a?r?)%s+(%d+)%s*$")
    local yaml_mark = yaml_mark_token and yaml_mark_token:sub(1, 1)
    if yaml_word and yaml_code and yaml_mark then
        return { mark = yaml_mark, append = yaml_mark_token == "+a", restore = yaml_mark_token == "+r", word = yaml_word, code = yaml_code, tx = yaml_tx }
    end
    yaml_word, yaml_code, yaml_mark_token = yaml_line:match("^([^\t#]+)\t([^%s#]+)%s*#%s*([+%-!%^]a?r?)%s*$")
    yaml_mark = yaml_mark_token and yaml_mark_token:sub(1, 1)
    if yaml_word and yaml_code and yaml_mark then
        return { mark = yaml_mark, append = yaml_mark_token == "+a", restore = yaml_mark_token == "+r", word = yaml_word, code = yaml_code }
    end
    local mark, word, code = line:match("^([+%-!%^])\t([^\t]+)\t([^\t%s]+)$")
    if not mark or not word or not code then return nil end
    return { mark = mark, word = word, code = code }
end

function M.pending_line(record, tx_fn)
    local mark = record.mark or "+"
    if record.append and mark == "+" then mark = "+a" end
    if record.restore and mark == "+" then mark = "+r" end
    local tx = record.tx or (tx_fn or new_tx)()
    return table.concat({ record.word or "", (record.code or "") .. " #" .. mark .. " " .. tx }, "\t")
end

function M.runtime_op(record)
    if record.op and record.op ~= "" then return record.op end
    if record.restore then return "restore" end
    if record.mark == "!" then return "delete" end
    if record.mark == "^" then return "order" end
    if record.mark == "-" then return "move" end
    if record.append then return "append" end
    return "make"
end

function M.runtime_line(record, tx_fn)
    local mark = record.mark or "+"
    if record.append and mark == "+" then mark = "+a" end
    if record.restore and mark == "+" then mark = "+r" end
    local tx = record.tx or (tx_fn or new_tx)()
    return table.concat({ tx, M.runtime_op(record), record.word or "", record.code or "", mark }, "\t")
end

function M.word_valid_at_code(pending, word, code)
    if not word or word == "" or not code or code == "" then return false end
    for i = #(pending or {}), 1, -1 do
        local record = pending[i]
        if record.word == word and record.code == code and record.mark ~= "^" then
            return record.mark ~= "!"
        end
    end
    return true
end

local function latest_state_for_code(pending, code)
    local latest, hidden = {}, {}
    if not code or code == "" then return latest, hidden end
    for i = #(pending or {}), 1, -1 do
        local record = pending[i]
        local word = record and record.word
        if record and record.code == code and word and word ~= "" and record.mark ~= "^" and latest[word] == nil then
            latest[word] = record
            if record.mark == "!" then hidden[word] = true end
        end
    end
    return latest, hidden
end

function M.build_effective_projection(input, pending, opts)
    opts = opts or {}
    local keep_rows, append_rows, keep_words, hide_words, seen_words = {}, {}, {}, {}, {}
    local append_words = {}
    local latest, latest_hidden = latest_state_for_code(pending, input)
    for word in pairs(latest_hidden) do hide_words[word] = true end
    local latest_order_tx = nil
    local latest_order_pos = nil
    if not opts.ignore_order then
        for i = #(pending or {}), 1, -1 do
            local record = pending[i]
            if record.code == input and record.mark == "^" and record.tx and record.tx ~= "" then
                latest_order_tx = record.tx
                latest_order_pos = i
                break
            end
        end
    end
    if latest_order_pos then
        for i = latest_order_pos + 1, #(pending or {}) do
            local record = pending[i]
            if record and record.code == input and record.mark ~= "^" and record.mark ~= "!" and not record.append then
                latest_order_tx = nil
                latest_order_pos = nil
                break
            end
        end
    end
    if latest_order_tx then
        local order_rows = {}
        for _, record in ipairs(pending or {}) do
            if record.code == input and record.mark == "^" and record.tx == latest_order_tx and not seen_words[record.word] and not latest_hidden[record.word] then
                order_rows[#order_rows + 1] = { word = record.word, code = record.code, source = "zzc_order" }
                keep_words[record.word] = true
                seen_words[record.word] = true
            end
        end
        for i = #(pending or {}), 1, -1 do
            local record = pending[i]
            if record.code == input and latest[record.word] == record and (record.mark == "+" or record.mark == "-" or record.restore)
                and not seen_words[record.word] then
                local row = { word = record.word, code = record.code, source = record.restore and "zzc_restore" or (record.append and "zzc_append" or "zzc") }
                if record.append then
                    if not append_words[record.word] then
                        hide_words[record.word] = nil
                        append_rows[#append_rows + 1] = row
                        append_words[record.word] = true
                    end
                elseif record.restore then
                    hide_words[record.word] = nil
                    order_rows[#order_rows + 1] = row
                    keep_words[record.word] = true
                    seen_words[record.word] = true
                else
                    order_rows[#order_rows + 1] = row
                    keep_words[record.word] = true
                    seen_words[record.word] = true
                end
            end
        end
        if order_rows[1] then
            return { rows = order_rows, append_rows = append_rows, keep_words = keep_words, hide_words = hide_words, has_order = true }
        end
    end
    for i = #(pending or {}), 1, -1 do
        local record = pending[i]
        if record.code == input and latest[record.word] == record then
            if (record.mark == "+" or record.mark == "-" or record.restore)
                and not seen_words[record.word] then
                local row = { word = record.word, code = record.code, source = record.restore and "zzc_restore" or (record.append and "zzc_append" or "zzc") }
                if record.append then
                    if not append_words[record.word] then
                        hide_words[record.word] = nil
                        append_rows[#append_rows + 1] = row
                        append_words[record.word] = true
                    end
                elseif record.restore then
                    hide_words[record.word] = nil
                    keep_rows[#keep_rows + 1] = row
                    keep_words[record.word] = true
                    seen_words[record.word] = true
                else
                    keep_rows[#keep_rows + 1] = row
                    keep_words[record.word] = true
                    seen_words[record.word] = true
                end
            end
        end
    end
    if not keep_rows[1] and not append_rows[1] then
        for _ in pairs(hide_words) do
            return { rows = keep_rows, append_rows = append_rows, keep_words = keep_words, hide_words = hide_words, has_delete_cover = true }
        end
        return nil
    end
    return { rows = keep_rows, append_rows = append_rows, keep_words = keep_words, hide_words = hide_words, has_exact_cover = keep_rows[1] ~= nil, has_append = append_rows[1] ~= nil }
end

function M.effective_state_snapshot(code, cover)
    local snapshot = { effective = { rows = {}, append_rows = {}, keep_words = {}, hide_words = {}, restore_rows = {} }, lines = {} }
    local effective = snapshot.effective
    for _, row in ipairs((cover and cover.rows) or {}) do
        snapshot.lines[#snapshot.lines + 1] = table.concat({ "visible", row.word or "", code or "", row.source or "zzc" }, "\t")
        effective.rows[#effective.rows + 1] = row
        effective.keep_words[row.word] = true
    end
    for _, row in ipairs((cover and cover.append_rows) or {}) do
        snapshot.lines[#snapshot.lines + 1] = table.concat({ "visible", row.word or "", code or "", row.source or "zzc_append" }, "\t")
        effective.append_rows[#effective.append_rows + 1] = row
    end
    for word in pairs((cover and cover.hide_words) or {}) do
        snapshot.lines[#snapshot.lines + 1] = table.concat({ "hidden", word or "", code or "", "zzc_restore" }, "\t")
        effective.hide_words[word] = true
        effective.restore_rows[#effective.restore_rows + 1] = { word = word, code = code, source = "zzc_restore" }
    end
    effective.has_order = cover and cover.has_order or nil
    effective.has_exact_cover = cover and cover.has_exact_cover or nil
    effective.has_append = cover and cover.has_append or nil
    effective.has_delete_cover = cover and cover.has_delete_cover or nil
    return snapshot
end

return M
