-- 天行键按键处理器运行状态管理
-- 作者：@浮生 https://github.com/wzxmer/rime-xmjd6
-- 更新：2026-07-10

local M = {}

function M.clear_space_guard(env)
    env._space_guard_input = nil
    env._space_guard_wait = nil
    env._space_guard_refreshed_input = nil
end

function M.init(env)
    env._ks = {}
    env._sw = nil
    env._dc = nil
    env._tc = nil
    env._tc_pending = true
    M.clear_space_guard(env)
    env._caps_blocked = nil
    env._caps_lock_on = nil
    env._shift_symbol_release_guard = nil
    env._shift_inline_ascii = nil
    env._calc_equal_allow_next = nil
end

function M.reset(env)
    M.clear_space_guard(env)
    env._calc_equal_allow_next = nil
    env._caps_lock_on = nil
    env._shift_inline_ascii = nil
end

function M.fini(env)
    env._ks = nil
    env._alpha = nil
    env._tu_set = nil
    env._rx_prefix = nil
    env._append_input_key = nil
    env._append_suffix_key = nil
    env._space_guard_enabled = nil
    env._direct_symbols_fast_leaf = nil
    M.clear_space_guard(env)
    env._caps_blocked = nil
    env._caps_lock_on = nil
    env._shift_symbol_release_guard = nil
    env._shift_inline_ascii = nil
    env._calc_equal_allow_next = nil
end

return M
