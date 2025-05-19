-- 优化版filter  来源：@浮生 https://github.com/wzxmer/rime-txjx

-- Lua Standard Functions (localize at the top)
local string_gsub = string.gsub
local string_match = string.match
local string_len = string.len -- Using # operator directly is also efficient

-- Module to be returned - DO NOT REMOVE THIS STRUCTURE
local M = {}

-- make_pattern_cache is primarily used by init to create escaped versions of s and b
-- for character class patterns. Its cache will be small (s and b).
local function make_pattern_cache()
    local cache = {}
    return function(s_char_class_part)
        if not s_char_class_part then return "" end
        local cached_val = cache[s_char_class_part]
        if not cached_val then
            cached_val = string_gsub(s_char_class_part, "([%-%]%^])", "%%%1")
            cache[s_char_class_part] = cached_val
        end
        return cached_val
    end
end

-- Optimized hint function.
-- It now returns two values: boolean (match found), string (lookup_text if match found, or nil)
-- This avoids a second reverse lookup in the filter function.
local function hint_optimized(cand_text_val, reverse_lookup_func,
                            s_char_val_from_env, b_char_val_from_env,
                            hint_patterns_from_env) -- This table comes from env, pre-built in init

    if string_len(cand_text_val) < 4 then return false, nil end

    -- Ensure hint patterns are available (set in init if s_char or b_char was present)
    if not hint_patterns_from_env then return false, nil end

    -- Perform reverse lookup once
    local looked_up_text = reverse_lookup_func(cand_text_val) -- Store the raw lookup text
    local lookup_result_str_for_match = " " .. looked_up_text .. " "

    local matched = false
    if s_char_val_from_env ~= "" and b_char_val_from_env ~= "" then
        matched = (hint_patterns_from_env.s_b_plus        and string_match(lookup_result_str_for_match, hint_patterns_from_env.s_b_plus)) or
                  (hint_patterns_from_env.s_s_b_dot_star  and string_match(lookup_result_str_for_match, hint_patterns_from_env.s_s_b_dot_star)) or
                  (hint_patterns_from_env.b_b_b_dot_star  and string_match(lookup_result_str_for_match, hint_patterns_from_env.b_b_b_dot_star))
    elseif s_char_val_from_env ~= "" then
        matched = (hint_patterns_from_env.s_s_dot_star    and string_match(lookup_result_str_for_match, hint_patterns_from_env.s_s_dot_star))
    elseif b_char_val_from_env ~= "" then
        matched = (hint_patterns_from_env.b_b_dot_star    and string_match(lookup_result_str_for_match, hint_patterns_from_env.b_b_dot_star))
    end

    if matched then
        return true, looked_up_text -- Return the lookup text
    end

    return false, nil
end

function M.filter(input, env)
    -- Cache frequently accessed Rime objects and options from env, set by init
    local engine_context = env.engine.context
    local is_danzi_mode_on = engine_context:get_option('danzi_mode')
    local show_sbb_hint_on = engine_context:get_option('sbb_hint')

    -- Use pre-cached values from env (set in init function)
    local no_commit_hint_text = env.cached_hint_text_str
    local s_char = env.cached_s_char_str             -- Raw s_char from config
    local b_char = env.cached_b_char_str             -- Raw b_char from config
    local no_commit_s_pattern = env.cached_no_commit_s_pattern_str -- Pre-built pattern for s
    local no_commit_b_pattern = env.cached_no_commit_b_pattern_str -- Pre-built pattern for b
    local reverse_lookup = env.cached_reverse_lookup_obj
    local hint_patterns = env.cached_hint_patterns_tbl

    local current_input = engine_context.input -- Read fresh, can change
    local current_input_len = string_len(current_input) -- Calculate once

    local apply_no_commit_hint = false
    if current_input_len < 4 then
        -- Use pre-built regex patterns. These are nil if s_char or b_char was empty.
        if s_char ~= "" and no_commit_s_pattern and string_match(current_input, no_commit_s_pattern) then
            apply_no_commit_hint = true
        end
        if not apply_no_commit_hint and b_char ~= "" and no_commit_b_pattern and string_match(current_input, no_commit_b_pattern) then
            apply_no_commit_hint = true
        end
    end

    for cand in input:iter() do
        local cand_text = cand.text
        local cand_text_len = string_len(cand_text)

        if apply_no_commit_hint and cand.type == "completion" then
            cand:get_genuine().comment = no_commit_hint_text
        end

        if not is_danzi_mode_on or cand_text_len < 4 then
            if show_sbb_hint_on then
                local hint_triggered, looked_up_text_for_comment = hint_optimized(
                    cand_text,
                    function(text_to_lookup) return reverse_lookup:lookup(text_to_lookup) end,
                    s_char, b_char, -- Pass raw s and b for logic inside hint_optimized
                    hint_patterns   -- Pass pre-built patterns
                )
                if hint_triggered then
                    local genuine_cand = cand:get_genuine()
                    local original_comment = genuine_cand.comment or ""
                    genuine_cand.comment = original_comment .. " = " .. looked_up_text_for_comment
                end
            end
            yield(cand)
        end
    end
end

function M.init(env)
    local schema_config = env.engine.schema.config
    local escape_for_char_class_fn = make_pattern_cache()

    -- Cache config values into env
    local s_char_from_config = schema_config:get_string("topup/topup_this") or ""
    local b_char_from_config = schema_config:get_string("topup/topup_with") or ""
    env.cached_s_char_str = s_char_from_config
    env.cached_b_char_str = b_char_from_config

    local dict_name_from_config = schema_config:get_string("translator/dictionary") or
                                  schema_config:get_string("engine/translator/dictionary") or ""
    env.cached_reverse_lookup_obj = ReverseLookup(dict_name_from_config)
    env.cached_hint_text_str = schema_config:get_string('hint_text') or '🚫'
    -- env.debug is not used in the filter logic, so caching it is optional unless needed elsewhere

    -- Pre-construct regex patterns for no_commit logic (uses char class escaping)
    if s_char_from_config ~= "" then
        env.cached_no_commit_s_pattern_str = "^[" .. escape_for_char_class_fn(s_char_from_config) .. "]+$"
    else
        env.cached_no_commit_s_pattern_str = nil
    end
    if b_char_from_config ~= "" then
        env.cached_no_commit_b_pattern_str = "^[" .. escape_for_char_class_fn(b_char_from_config) .. "]+$"
    else
        env.cached_no_commit_b_pattern_str = nil
    end

    -- Pre-construct regex patterns for hint_optimized function
    -- These patterns directly concatenate s_char_from_config and b_char_from_config.
    -- **CRITICAL**: If s_char_from_config or b_char_from_config can contain Lua pattern
    -- metacharacters (e.g., '.', '%', '(', ')', '*', '+', '-', '^', '$', '[', ']')
    -- and they are NOT intended to be metacharacters in these hint patterns,
    -- they MUST be escaped using a general Lua pattern escaper PRIOR to this concatenation.
    -- Example: local s_for_hint = escape_lua_pattern_meta(s_char_from_config)
    -- This version assumes direct concatenation is the intended behavior based on the original script.
    local s_for_hint_pattern_build = s_char_from_config
    local b_for_hint_pattern_build = b_char_from_config

    if s_for_hint_pattern_build ~= "" or b_for_hint_pattern_build ~= "" then
        env.cached_hint_patterns_tbl = {}
        if s_for_hint_pattern_build ~= "" and b_for_hint_pattern_build ~= "" then
            env.cached_hint_patterns_tbl.s_b_plus = " " .. s_for_hint_pattern_build .. b_for_hint_pattern_build .. "+ "
            env.cached_hint_patterns_tbl.s_s_b_dot_star = " " .. s_for_hint_pattern_build .. s_for_hint_pattern_build .. b_for_hint_pattern_build .. ".* "
            env.cached_hint_patterns_tbl.b_b_b_dot_star = " " .. b_for_hint_pattern_build .. b_for_hint_pattern_build .. b_for_hint_pattern_build .. ".* "
        end
        if s_for_hint_pattern_build ~= "" then
            env.cached_hint_patterns_tbl.s_s_dot_star = " " .. s_for_hint_pattern_build .. s_for_hint_pattern_build .. ".* "
        end
        if b_for_hint_pattern_build ~= "" then
            if not env.cached_hint_patterns_tbl.b_b_b_dot_star and s_for_hint_pattern_build == "" then
                 env.cached_hint_patterns_tbl.b_b_b_dot_star = " " .. b_for_hint_pattern_build .. b_for_hint_pattern_build .. b_for_hint_pattern_build .. ".* "
            end
            env.cached_hint_patterns_tbl.b_b_dot_star = " " .. b_for_hint_pattern_build .. b_for_hint_pattern_build .. ".* "
        end
        -- Ensure all expected keys might exist, even if nil, if only one of s/b is present
        -- This helps hint_optimized to safely check for pattern existence.
        env.cached_hint_patterns_tbl.s_b_plus = env.cached_hint_patterns_tbl.s_b_plus
        env.cached_hint_patterns_tbl.s_s_b_dot_star = env.cached_hint_patterns_tbl.s_s_b_dot_star
        env.cached_hint_patterns_tbl.b_b_b_dot_star = env.cached_hint_patterns_tbl.b_b_b_dot_star
        env.cached_hint_patterns_tbl.s_s_dot_star = env.cached_hint_patterns_tbl.s_s_dot_star
        env.cached_hint_patterns_tbl.b_b_dot_star = env.cached_hint_patterns_tbl.b_b_dot_star
    else
        env.cached_hint_patterns_tbl = nil -- No s or b, so no hint patterns table needed.
    end

    -- Original env.escape is no longer needed by filter as patterns are pre-built or use specific escaping.
    -- However, if other parts of your setup (not shown) relied on env.escape, you might need to keep it.
    -- For this specific filter's optimization, it's not directly used by M.filter anymore.
    -- Let's keep it as per original init, in case it's a general utility.
    env.escape = escape_for_char_class_fn
end

-- Crucial: Export the init and filter functions for Rime
return { init = M.init, func = M.filter }