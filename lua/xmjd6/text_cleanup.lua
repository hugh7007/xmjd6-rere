-- text_cleanup.lua
-- 候选文本清理 filter 合集（合并自 add_space.lua / split.lua）
--
-- 两个 filter 做的都是"扫描候选文本、按规则改写后透传"，无共享状态、
-- 无 require 依赖、无 init/fini，因此合并成本为零。
--
-- 拼装规则：模块里的函数若名为 M.<name>，则 `lua_filter@*xmjd6/text_cleanup@<name>`
-- 取到它；因此两个挂载点分别写 @add_space 与 @split。

local M = {}

-- =====================================================================
-- 第一部分：add_space（原 add_space.lua）
-- 把候选文本里的 | 换成空格、\n 换成真换行
-- =====================================================================
function M.add_space(input, env)
    for cand in input:iter() do
        local hasGun = (string.find(cand.text, "|") or string.find(cand.text, "\\n"))
        if hasGun then
            local str = cand.text
            str = string.gsub(str, "|", " ")
            str = string.gsub(str, "\\n", "\n")
            yield(Candidate(cand.type, cand.start, cand._end, str, cand:get_genuine().comment))
        else
            yield(cand)
        end
    end
end

-- =====================================================================
-- 第二部分：split（原 split.lua）
-- 候选文本含空格时，按 ` 分隔符拆出正文与注释
-- =====================================================================
function M.split(input, env)
    for cand in input:iter() do
        local hasSpace = string.find(cand.text, " ")
        if hasSpace then
            local delimiter = string.find(cand.text, "`[^`]*$")
            if delimiter == nil then
                yield(cand)
            else
                local word = string.sub(cand.text, 1, delimiter - 1)
                local comment = string.sub(cand.text, delimiter + 1)
                if word == "" or comment == "" then
                    yield(cand)
                else
                    local original_comment = cand:get_genuine().comment
                    if word:sub(1, 1) ~= "$" then
                        yield(Candidate(cand.type, cand.start, cand._end, word, original_comment .. comment))
                    else
                        yield(Candidate(word, cand.start, cand._end, original_comment .. comment, ""))
                    end
                end
            end
        else
            local str = cand.text
            if string.sub(str, -1) == "`" then
                str = string.sub(str, 1, -2)
                yield(Candidate(cand.type, cand.start, cand._end, str, cand:get_genuine().comment))
            else
                yield(cand)
            end
        end
    end
end

-- ════════════════════════════════════════════════════════════════
-- 导出：librime-lua 的 raw_init 一律硬取 .func，@ 后缀只落进 env.name_space
-- 供模块内自行分流（不会用来选函数）。因此两个 filter 共用一个 .func，
-- 由 env.name_space 决定走哪一路。
--   lua_filter@*xmjd6/text_cleanup@add_space  → env.name_space == "add_space"
--   lua_filter@*xmjd6/text_cleanup@split      → env.name_space == "split"
-- ════════════════════════════════════════════════════════════════
local NAME_SPACE_FUNCS = {
    add_space = M.add_space,
    split = M.split,
}

function M.func(input, env)
    local ns = env and env.name_space
    -- name_space 实测为 "add_space" / "split" 这种纯名字；
    -- 兼容万一被拼成 "*xmjd6/text_cleanup@split" 的情况。
    local key = nil
    if type(ns) == "string" then
        key = ns:match("@([%w_]+)$") or ns:match("^([%w_]+)$")
    end
    local fn = key and NAME_SPACE_FUNCS[key]
    if fn then
        return fn(input, env)
    end
    -- 兜底：无 @ 时只跑 add_space（纯改写、可安全叠加）
    return M.add_space(input, env)
end

return M
