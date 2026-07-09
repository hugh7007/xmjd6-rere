-- 补全候选过滤器
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-05

local config_util = require("common.xmjd6_config")
local candidate_util = require("common.xmjd6_candidate")
local zzc_core = require("zzc.xmjd6_zzc_core")

local type = type
local COMPLETION_LIMIT = 30
local COMPLETION_MAX_CODE_LEN = 5
local direct_symbols_cache

local function is_reverse_lookup_context(ctx, env)
    return config_util.is_reverse_context(ctx, env and env._reverse_tags, env and env._reverse_prefixes)
end

local function trim_trailing_sep(path)
    return (path or ""):gsub("[/\\]+$", "")
end

local function dirname(path)
    return (path or ""):match("^(.*)[/\\][^/\\]*$") or ""
end

local function join_path(base, name)
    if not base or base == "" then return name end
    return base .. "/" .. name
end

local function module_project_dir()
    local info = debug and debug.getinfo and debug.getinfo(1, "S") or nil
    local source = info and info.source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    source = source:gsub("\\", "/")
    local lua_dir = dirname(source)
    if lua_dir:match("/lua$") or lua_dir == "lua" then
        return dirname(lua_dir)
    end
    return lua_dir
end

local function push_unique_path(list, seen, path)
    path = trim_trailing_sep(path)
    if path ~= "" and not seen[path] then
        seen[path] = true
        list[#list + 1] = path
    end
end

local function core_dict_candidates(schema_id)
    local file_name = ((schema_id and schema_id ~= "") and schema_id or "xmjd6") .. ".core.dict.yaml"
    local candidates, seen = {}, {}
    push_unique_path(candidates, seen, file_name)
    push_unique_path(candidates, seen, join_path(module_project_dir(), file_name))
    local api = rime_api
    if api and api.get_user_data_dir then
        local ok, user_dir = pcall(api.get_user_data_dir)
        if ok and type(user_dir) == "string" and user_dir ~= "" then
            push_unique_path(candidates, seen, join_path(user_dir, file_name))
        end
    end
    return candidates
end

local function find_existing_path(candidates)
    for _, path in ipairs(candidates or {}) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

local function load_direct_symbols(schema_id)
    local path = find_existing_path(core_dict_candidates(schema_id))
    local state = { rows = {}, max_len = 0 }
    if not path then return state end
    local f = io.open(path, "r")
    if not f then return state end
    local in_region = false
    for line in f:lines() do
        if line:match("^%s*#region%s+<快符>%s*$") then
            in_region = true
        elseif line:match("^%s*#endregion%s+<快符>%s*$") then
            break
        elseif in_region and not line:match("^%s*#") then
            local text, code = line:match("^([^\t]+)\t(;%S+)")
            if text and code and code ~= "" then
                state.rows[#state.rows + 1] = { text = text, code = code }
                if #code > state.max_len then state.max_len = #code end
            end
        end
    end
    f:close()
    return state
end

local function direct_symbols_state(env)
    if not direct_symbols_cache then
        direct_symbols_cache = load_direct_symbols(env and env.engine and env.engine.schema and env.engine.schema.schema_id or "xmjd6")
    end
    return direct_symbols_cache
end

local function zzc_completion_visible(cover, text)
    if not text or text == "" then return true end
    if not cover then return true end
    return not cover.keep_words[text] and not cover.hide_words[text]
end

local function completion_remaining(cand, input_text)
    local comment = cand and cand.comment or ""
    if type(comment) == "string" then
        local rest = comment:match("^~(.+)$")
        if rest then return rest end
    end
    local text = cand and cand.text or ""
    return text:sub(#(input_text or "") + 1)
end

local function completion_stroke_key(code)
    code = code or ""
    if #code < 5 then return "" end
    return code:sub(5, 6)
end

local function push_completion(buffer, cand, input_text, source_rank, ordinal, sort_code)
    local text_len = candidate_util.utf8_len(cand.text)
    local rest = completion_remaining(cand, input_text)
    local code = sort_code
    if not code or code == "" then
        code = (input_text or "") .. (rest or "")
    end
    buffer[#buffer + 1] = {
        cand = cand,
        text_len = text_len or 999,
        code = code,
        code_len = #(code or ""),
        stroke_key = completion_stroke_key(code),
        rest_len = #(rest or ""),
        source_rank = source_rank or 2,
        ordinal = ordinal or #buffer + 1,
    }
end

local function sort_completion_buffer(buffer)
    table.sort(buffer, function(left, right)
        if left.code_len ~= right.code_len then return left.code_len < right.code_len end
        if left.stroke_key ~= right.stroke_key then return (left.stroke_key or "") < (right.stroke_key or "") end
        local left_single = left.text_len == 1
        local right_single = right.text_len == 1
        if left_single ~= right_single then return left_single end
        if left.code ~= right.code then return (left.code or "") < (right.code or "") end
        if left.source_rank ~= right.source_rank then return left.source_rank < right.source_rank end
        if left.text_len ~= right.text_len then return left.text_len < right.text_len end
        return left.ordinal < right.ordinal
    end)
end

local function push_zzc_completion_rows(rows, input_text, buffer, seen, limit)
    if not rows or not rows[1] or not input_text or input_text == "" then return end
    local pushed = 0
    for _, row in ipairs(rows) do
        if pushed >= limit then break end
        local word = row.word
        local code = row.code
        if word and word ~= "" and code and code:sub(1, #input_text) == input_text and not seen[word] then
            local remaining = code:sub(#input_text + 1)
            local comment = remaining ~= "" and ("~" .. remaining) or "自造词"
            local cand = Candidate("completion", 0, #input_text, word, comment)
            cand.quality = 10055 - #code
            push_completion(buffer, cand, input_text, 1, #buffer + 1, code)
            seen[word] = true
            pushed = pushed + 1
        end
    end
end

local function push_direct_symbols_completion_rows(env, input_text, buffer, seen, limit)
    if not input_text or input_text:sub(1, 1) ~= ";" then return end
    local state = direct_symbols_state(env)
    if not state or not state.rows or not state.rows[1] then return end
    local pushed = 0
    for _, row in ipairs(state.rows) do
        if pushed >= limit then break end
        local code = row.code
        local text = row.text
        if code and text and code:sub(1, #input_text) == input_text and not seen[text] then
            local remaining = code:sub(#input_text + 1)
            local comment = remaining ~= "" and ("~" .. remaining) or "快符"
            local cand = Candidate("completion", 0, #input_text, text, comment)
            cand.quality = 10040 - #code
            push_completion(buffer, cand, input_text, 2, #buffer + 1, code)
            seen[text] = true
            pushed = pushed + 1
        end
    end
end

local function zzc_completion_count(buffer)
    local count = 0
    for _, item in ipairs(buffer or {}) do
        local cand_type = item.cand and item.cand.type
        if item.source_rank == 1
            or cand_type == "zzc_completion"
            or cand_type == "zzc_cover"
            or cand_type == "zzc_append" then
            count = count + 1
        end
    end
    return count
end

local function push_zzc_append_rows(rows, input_text, buffer, seen)
    if not rows or not rows[1] then return end
    for _, row in ipairs(rows) do
        local word = row.word
        if word and word ~= "" and not seen[word] then
            local cand = Candidate("zzc_append", 0, #(input_text or ""), word, "自造词")
            cand.quality = 8000
            buffer[#buffer + 1] = cand
            seen[word] = cand
        end
    end
end

return {
    init = function(env)
        local config = env.engine.schema.config
        env._danzi_first = not (config:get_bool("translator/enable_sentence") or false)
        env._reverse_tags, env._reverse_prefixes = config_util.collect_reverse_context(
            config,
            env.engine.schema.schema_id or "",
            false
        )
    end,

    func = function(input, env)
        local ctx = env.engine and env.engine.context
        local input_text = ctx and ctx.input or ""
        local input_len = #input_text
        local direct_symbols_input = input_text:sub(1, 1) == ";"
        local enabled = ctx and ctx:get_option("completion") or false
        local allow_native_completion = enabled and not direct_symbols_input and input_len <= COMPLETION_MAX_CODE_LEN
        local allow_zzc_completion = allow_native_completion
        local danzi = env._danzi_first
        local reverse_lookup = nil
        local buffer = {}
        local buffer_size = 0
        local zzc_append_buffer = {}
        local zzc_append_size = 0
        local completion_buffer = {}
        local comp_count = 0
        local zzc_cover = input_text ~= "" and zzc_core.zzc_cover_for_input(input_text) or nil
        local zzc_stage = ctx and ctx.get_property and (ctx:get_property("_xmjd6_zzc_stage") or "") or ""
        local zzc_mode = ctx and ctx.get_property and (ctx:get_property("_xmjd6_zzc_mode") or "") or ""
        local zzc_target = ctx and ctx.get_property and (ctx:get_property("_xmjd6_zzc_target") or "") or ""
        if not zzc_cover and zzc_stage == "collect" and zzc_target ~= "" and (zzc_mode == "append" or zzc_mode == "replace") then
            zzc_cover = zzc_core.zzc_cover_for_input(zzc_target)
        end
        local zzc_completion_rows = nil
        if allow_zzc_completion then
            zzc_completion_rows = zzc_core.zzc_completion_rows_for_prefix(input_text, COMPLETION_LIMIT)
        end
        local zzc_completion_seen = {}
        if enabled and direct_symbols_input then
            push_direct_symbols_completion_rows(env, input_text, completion_buffer, zzc_completion_seen, COMPLETION_LIMIT)
        end
        push_zzc_completion_rows(
            zzc_completion_rows,
            input_text,
            completion_buffer,
            zzc_completion_seen,
            COMPLETION_LIMIT
        )
        local remaining_completion_limit = COMPLETION_LIMIT - zzc_completion_count(completion_buffer)
        if remaining_completion_limit < 0 then remaining_completion_limit = 0 end
        local zzc_append_seen = {}
        if zzc_cover and zzc_cover.append_rows then
            push_zzc_append_rows(zzc_cover.append_rows, input_text, zzc_append_buffer, zzc_append_seen)
            zzc_append_size = #zzc_append_buffer
        end

        for cand in input:iter() do
            if cand.type == "history" then
                yield(cand)
                goto continue
            end
            if cand.type == "zzc_append" then
                local existing = zzc_append_seen[cand.text]
                if existing then
                    if cand.comment and cand.comment ~= "" and cand.comment ~= "自造词" then
                        existing.comment = cand.comment
                    end
                    if cand.preedit and cand.preedit ~= "" then
                        existing.preedit = cand.preedit
                    end
                else
                    zzc_append_size = zzc_append_size + 1
                    zzc_append_buffer[zzc_append_size] = cand
                    zzc_append_seen[cand.text] = cand
                end
                goto continue
            end
            if type(cand.type) == "string" and cand.type:match("^zzc_") then
                yield(cand)
                goto continue
            end
            if cand.type == "completion" then
                if zzc_completion_seen[cand.text] then
                    goto continue
                end
                if not zzc_completion_visible(zzc_cover, cand.text) then
                    goto continue
                end
                if reverse_lookup == nil then
                    reverse_lookup = is_reverse_lookup_context(ctx, env)
                end
                if reverse_lookup then
                    break
                end
                if not allow_native_completion then break end
                if comp_count >= remaining_completion_limit then break end
                comp_count = comp_count + 1
                push_completion(completion_buffer, cand, input_text, 2, comp_count)
                goto continue
            end
            if not danzi then
                yield(cand)
            else
                local c = cand.comment
                if c and type(c) == "string" and #c == 0 then
                    yield(cand)
                else
                    local text_len = candidate_util.utf8_len(cand.text)
                    if text_len == 1 then
                        yield(cand)
                    elseif text_len and text_len > 1 then
                        buffer_size = buffer_size + 1
                        buffer[buffer_size] = cand
                    end
                end
            end
            ::continue::
        end

        for i = 1, buffer_size do
            yield(buffer[i])
        end
        for i = 1, zzc_append_size do
            yield(zzc_append_buffer[i])
        end
        sort_completion_buffer(completion_buffer)
        for i = 1, #completion_buffer do
            yield(completion_buffer[i].cand)
        end
    end,

    fini = function(env)
        env._danzi_first = nil
        env._reverse_tags = nil
        env._reverse_prefixes = nil
    end
}
