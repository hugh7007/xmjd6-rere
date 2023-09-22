local core = {}

-- 由translator記録輸入串, 傳遞給filter
core.input_code = ''
-- 由translator計算暫存串, 傳遞給filter
core.stashed_text = ''
-- 由translator初始化基础碼表數據
core.base_mem = nil
-- 附加官宇詞庫
core.full_mem = nil
core.yuhao_mem = nil

-- 消息同步: 更新時間
core.sync_at = 0
-- 消息同步: 總線
core.sync_bus = {
    switches = {}, -- 開關狀態
}

-- 輸入 "zhelp" 時提供開關管理
core.helper_code = "zhelp"
-- 開關枚舉
core.switch_types = { switch = 1, radio = 2 }
core.switch_names = {
    single_char = "single_char",
    fullcode_char = "fullcode_char",
    embeded_cands = "embeded_cands",
}

-- 新開關
local function new_switch(name, display)
    return {
        type = core.switch_types.switch,
        name = name,
        display = display,
    }
end
-- 新單選
local function new_radio(states)
    return {
        type = core.switch_types.radio,
        states = states,
    }
end
-- 開關列表
core.switch_options = {
    new_switch("ascii_punct", {"Punct", "標點"}),
    new_switch(core.switch_names.single_char, {"純單", "智能"}),
    new_switch(core.switch_names.fullcode_char, {"全單", "字詞"}),
    new_switch(core.switch_names.embeded_cands, {"嵌入開", "嵌入關"}),
    new_switch("full_shape", {"全角", "半角"}),
    new_radio({
        { name = "division.off", display = "註解關" },
        { name = "division.lv1", display = "註解一" },
        { name = "division.lv2", display = "註解二" },
    }),
}

-- ######## 工具函数 ########

-- 從方案配置中讀取字符串
function core.parse_conf_str(env, path, default)
    local str = env.engine.schema.config:get_string(env.name_space.."/"..path)
    if not str and default and #default ~= 0 then
        str = default
    end
    return str
end

-- 從方案配置中讀取字符串列表
function core.parse_conf_str_list(env, path, default)
    local list = {}
    local conf_list = env.engine.schema.config:get_list(env.name_space.."/"..path)
    if conf_list then
        for i = 0, conf_list.size-1 do
            table.insert(list, conf_list:get_value_at(i).value)
        end
    elseif default then
        list = default
    end
    return list
end

-- 是否單個宇三全碼編碼段, 如: "abc", "a;", "a;;", "ab;"
function core.single_smyh_seg(input)
    return string.match(input, "^[a-y][z;]$")       -- 一簡
        or string.match(input, "^[a-y][z;][z;]$")   -- 一簡詞
        or string.match(input, "^[a-y][a-y][z;]$")  -- 二簡詞
        or string.match(input, "^[a-y][a-y][a-y]$") -- 單字全碼
end

-- 是否合法宇三分詞串
function core.valid_smyh_input(input)
    -- 輸入串完全由 [a-z;] 構成, 且不以 [z;] 開頭
    return string.match(input, "^[a-z;]*$") and not string.match(input, "^[z;]")
end

-- 構造開關變更回調函數
function core.get_switch_handler(env, option_name)
    local option
    if not env.option then
        option = {}
        env.option = option
    else
        option = env.option
    end
    -- 返回通知回調, 當改變選項值時更新暫存的值
    return function(ctx, name)
        if name == option_name then
            option[name] = ctx:get_option(name)
            if option[name] == nil then
                -- 當選項不存在時默認爲啟用狀態
                option[name] = true
            end
        end
    end
end

-- 计算分词列表
-- "dkdqgxfvt;" -> ["dkd","qgx","fvt"], ";"
-- "d;nua"     -> ["d;", "nua"]
core.get_code_segs = function(input)
    local code_segs = {}
    while string.len(input) ~= 0 do
        if string.match(string.sub(input, 1, 2), "[a-y][z;]") then
            if string.match(string.sub(input, 1, 3), "[a-y][z;][z;]") then
                -- 匹配到一简词
                table.insert(code_segs, string.sub(input, 1, 3))
                input = string.sub(input, 4)
            else
                -- 匹配到一简
                table.insert(code_segs, string.sub(input, 1, 2))
                input = string.sub(input, 3)
            end
        elseif string.match(string.sub(input, 1, 3), "[a-y][a-y][a-z;]") then
            -- 匹配到全码或二简
            table.insert(code_segs, string.sub(input, 1, 3))
            input = string.sub(input, 4)
        -- elseif input == ";" then
        --     -- 匹配到冗余分号
        --     break
        else
            -- 不完整或不合法分词输入串
            return code_segs, input
        end
    end
    return code_segs, input
end

-- 查询编码对应候选列表
-- "dkd" -> ["南", "電"]
core.dict_lookup = function(mem, code, count, comp)
    -- 是否补全编码
    count = count or 1
    comp = comp or false
    local result = {}
    if not mem then
        return result
    end
    code = string.gsub(code, "z", ";")
    if mem:dict_lookup(code, comp, count) then
        for entry in mem:iter_dict() do
            table.insert(result, entry)
        end
    end
    return result
end

-- 查詢分詞首選列表
core.query_first_cand_list = function(mem, code_segs)
    local cand_list = {}
    for _, code in ipairs(code_segs) do
        local entries = core.dict_lookup(mem, code)
        if #entries ~= 0 then
            table.insert(cand_list, entries[1].text)
        else
            table.insert(cand_list, "")
        end
    end
    return cand_list
end

-- 最大匹配查詢分詞候選列表
-- ["dkd", "qgx", "fvt"] -> ["電動", "杨"]
-- ["dkd", "qgx"]        -> ["南", "動"]
core.query_cand_list = function(mem, code_segs, skipfull)
    local index = 1
    local cand_list = {}
    local code = table.concat(code_segs, "", index)
    while index <= #code_segs do
        -- 最大匹配
        for viewport = #code_segs, index, -1 do
            if not skipfull or viewport-index+1 < #code_segs then
                code = table.concat(code_segs, "", index, viewport)
                local entries = core.dict_lookup(mem, code)
                if entries[1] then
                    -- 當前viewport有候選, 擇之並進入下一輪
                    table.insert(cand_list, entries[1].text)
                    index = viewport + 1
                    break
                elseif viewport == index then
                    -- 最小viewport無候選, 以空串作爲候選
                    table.insert(cand_list, "")
                    index = viewport + 1
                    break
                end
            end
        end
    end
    -- 返回候選字列表及末候選編碼
    return cand_list, code
end

return core
