-- 将要被返回的過濾器對象
local embeded_cands_filter = {}
local core = require("xmjd6/xmjd6_embeded_core")


--[[
# xxx.schema.yaml
switches:
  - name: embeded_cands
    states: [ 普通, 嵌入 ]
    reset: 1
engine:
  filters:
    - lua_filter@*smyh.embeded_cands
key_binder:
  bindings:
    - { when: always, accept: "Control+Shift+E", toggle: embeded_cands }
--]]

local index_indicators = { "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹", "⁰" }

-- 首選/非首選格式定義
-- Stash: 延迟候選; Seq: 候選序號; Code: 編碼; 候選: 候選文本; Comment: 候選提示
local first_format = "${Stash}[${候選}${Seq}]${Code}${Comment}"
local next_format = "${Stash}${候選}${Seq}${Comment}"
local separator = " "
local stash_placeholder = "~"

local function compile_formatter(format)
    -- "${Stash}[${候選}${Seq}]${Code}${Comment}"
    -- => "%s[%s%s]%s%s"
    -- => {"${Stash}", "${...}", "${...}", ...}
    local pattern = "%$%{[^{}]+%}"
    local verbs = {}
    for s in string.gmatch(format, pattern) do
        table.insert(verbs, s)
    end

    local res = {
        format = string.gsub(format, pattern, "%%s"),
        verbs = verbs,
    }
    local meta = { __index = function() return "" end }

    -- {"${v1}", "${v2}", ...} + {v1: a1, v2: a2, ...} = {a1, a2, ...}
    -- string.format("%s[%s%s]%s%s", a1, a2, ...)
    function res:build(dict)
        setmetatable(dict, meta)
        local args = {}
        for _, pat in ipairs(self.verbs) do
            table.insert(args, dict[pat])
        end
        return string.format(self.format, table.unpack(args))
    end

    return res
end


-- 按命名空間歸類方案配置, 而不是按会話, 以减少内存佔用
local namespaces = {}

function namespaces:init(env)
    if not namespaces:config(env) then
        -- 讀取配置項
        local config = {}
        config.index_indicators = core.parse_conf_str_list(env, "index_indicators", index_indicators)
        config.first_format = core.parse_conf_str(env, "first_format", first_format)
        config.next_format = core.parse_conf_str(env, "next_format", next_format)
        config.separator = core.parse_conf_str(env, "separator", separator)
        config.stash_placeholder = core.parse_conf_str(env, "stash_placeholder", stash_placeholder)

        config.formatter = {}
        config.formatter.first = compile_formatter(config.first_format)
        config.formatter.next = compile_formatter(config.next_format)
        namespaces:set_config(env, config)
    end
end

function namespaces:set_config(env, config)
    namespaces[env.name_space] = namespaces[env.name_space] or {}
    namespaces[env.name_space].config = config
end

function namespaces:config(env)
    return namespaces[env.name_space] and namespaces[env.name_space].config
end

function embeded_cands_filter.init(env)
    -- 讀取配置項
    local ok = pcall(namespaces.init, namespaces, env)
    if not ok then
        local config = {}
        config.index_indicators = index_indicators
        config.first_format = first_format
        config.next_format = next_format
        config.separator = separator
        config.stash_placeholder = stash_placeholder

        config.formatter = {}
        config.formatter.first = compile_formatter(config.first_format)
        config.formatter.next = compile_formatter(config.next_format)
        namespaces:set_config(env, config)
    end

    -- 構造回調函數
    local option_names = {
        [core.switch_names.embeded_cands] = true,
    }
    local handler = core.get_switch_handler(env, option_names)
    -- 初始化爲選項實際值, 如果設置了 reset, 則會再次觸發 handler
    for name in pairs(option_names) do
        handler(env.engine.context, name)
    end
    -- 注册通知回調
    env.engine.context.option_update_notifier:connect(handler)
end

-- 處理候選文本和延迟串
local function render_stashcand(env, seq, stash, text, digested)
    if string.len(stash) ~= 0 and string.match(text, "^" .. stash) then
        if seq == 1 then
            -- 首選含延迟串, 原樣返回
            digested = true
            stash, text = stash, string.sub(text, string.len(stash) + 1)
        elseif not digested then
            -- 首選不含延迟串, 其他候選含延迟串, 標記之
            digested = true
            stash, text = "[" .. stash .. "]", string.sub(text, string.len(stash) + 1)
        else
            -- 非首個候選, 延迟串標記爲空
            local placeholder = string.gsub(namespaces:config(env).stash_placeholder, "%${Stash}", stash)
            stash, text = "", placeholder .. string.sub(text, string.len(stash) + 1)
        end
    else
        -- 普通候選, 延迟串標記爲空
        stash, text = "", text
    end
    return stash, text, digested
end

-- 渲染提示, 因爲提示經常有可能爲空, 抽取爲函數更易操作
local function render_comment(comment)
    if string.match(comment, "^~") then
        -- 丟棄以"~"開頭的提示串, 這通常是補全提示
        comment = ""
    else
        -- 自定義提示串格式
        -- comment = "<"..comment..">"
    end
    return comment
end

-- 渲染單個候選項
local function render_cand(env, seq, code, stashed, text, comment, digested)
    local formatter
    -- 選擇渲染格式
    if seq == 1 then
        formatter = namespaces:config(env).formatter.first
    else
        formatter = namespaces:config(env).formatter.next
    end
    -- 渲染延迟串與候選文字
    stashed, text, digested = render_stashcand(env, seq, stashed, text, digested)
    if seq ~= 1 and text == "" then
        return "", digested
    end
    -- 渲染提示串
    comment = render_comment(comment)
    local cand = formatter:build({
        ["${Seq}"] = namespaces:config(env).index_indicators[seq],
        ["${Code}"] = code,
        ["${Stash}"] = stashed,
        ["${候選}"] = text,
        ["${Comment}"] = comment,
    })
    return cand, digested
end


-- 過濾器
function embeded_cands_filter.func(input, env)
    if not env.option[core.switch_names.embeded_cands] then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    -- 要顯示的候選數量
    local page_size = env.engine.schema.page_size
    -- 暫存當前頁候選, 然后批次送出
    local page_cands, page_rendered = {}, {}
    -- 暫存索引, 首選和預編輯文本
    local index, first_cand, preedit = 0, nil, ""
    local digested = false

    local function refresh_preedit()
        first_cand.preedit = table.concat(page_rendered, namespaces:config(env).separator)
        -- 將暫存的一頁候選批次送出
        for _, c in ipairs(page_cands) do
            yield(c)
        end
        -- 清空暫存
        first_cand, preedit = nil, ""
        page_cands, page_rendered = {}, {}
        digested = false
    end

    -- 迭代器
    local iter, obj = input:iter()
    -- 迭代由翻譯器輸入的候選列表
    local next = iter(obj)
    -- local first_stash = true
    while next do
        -- 頁索引自增, 滿足 1 <= index <= page_size
        index = index + 1
        -- 當前遍歷候選項
        local cand = next

        if index == 1 then
            -- 把首選捉出來
            first_cand = cand:get_genuine()
        end

        -- 活動輸入串
        local input_code = ""
        if string.len(core.input_code) == 0 then
            input_code = cand.preedit
        else
            input_code = core.input_code
        end

        -- 帶有暫存串的候選合併同類項
        preedit, digested = render_cand(env, index, input_code, core.stashed_text, cand.text, cand.comment, digested)

        -- 存入候選
        table.insert(page_cands, cand)
        if #preedit ~= 0 then
            table.insert(page_rendered, preedit)
        end

        -- 遍歷完一頁候選後, 刷新預編輯文本
        if index == page_size then
            refresh_preedit()
        end

        -- 當前候選處理完畢, 查詢下一個
        next = iter(obj)

        -- 如果當前暫存候選不足page_size但没有更多候選, 則需要刷新預編輯並送出
        if not next and index < page_size then
            refresh_preedit()
        end

        -- 下一頁, index歸零
        index = index % page_size
    end
end

function embeded_cands_filter.fini(env)
    env.option = nil
end

return embeded_cands_filter