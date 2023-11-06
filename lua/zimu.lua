-- 字母数字转成对应的𝑨𝑩𝑪𝑫𝑬𝑭𝑮𝑯𝑰𝑱𝑲𝑳𝑴𝑵𝑶𝑷𝑸𝑹𝑺𝑻𝑼𝑽𝑾𝑿𝒀𝒁𝟎𝟏𝟐𝟑𝟒𝟓𝟔𝟕𝟖𝟗𝟬𝟭𝟮𝟯𝟰𝟱𝟲𝟳𝟵
local alphabet = {
	a = '𝒂',
    b = '𝒃',
    c = '𝒄',
    d = '𝒅',
    e = '𝒆',
    f = '𝒇',
    g = '𝒈',
    h = '𝒉',
    i = '𝒊',
    j = '𝒋',
    k = '𝒌',
    l = '𝒍',
    m = '𝒎',
    n = '𝒏',
    o = '𝒐',
    p = '𝒑',
    q = '𝒒',
    r = '𝒓',
    s = '𝒔',
    t = '𝒕',
    u = '𝒖',
    v = '𝒗',
    w = '𝒘',
    x = '𝒙',
    y = '𝒚',
    z = '𝒛',
    ['0'] = '𝟶',
    ['1'] = '𝟷',
    ['2'] = '𝟸',
    ['3'] = '𝟹',
    ['4'] = '𝟺',
    ['5'] = '𝟻',
    ['6'] = '𝟼',
    ['7'] = '𝟽',
    ['8'] = '𝟾',
    ['9'] = '𝟿'
}
local alphabet2 = {
    a = '𝑨',
    b = '𝑩',
    c = '𝑪',
    d = '𝑫',
    e = '𝑬',
    f = '𝑭',
    g = '𝑮',
    h = '𝑯',
    i = '𝑰',
    j = '𝑱',
    k = '𝑲',
    l = '𝑳',
    m = '𝑴',
    n = '𝑵',
    o = '𝑶',
    p = '𝑷',
    q = '𝑸',
    r = '𝑹',
    s = '𝑺',
    t = '𝑻',
    u = '𝑼',
    v = '𝑽',
    w = '𝑾',
    x = '𝑿',
    y = '𝒀',
    z = '𝒁',
    ['0'] = '𝟬',
    ['1'] = '𝟭',
    ['2'] = '𝟮',
    ['3'] = '𝟯',
    ['4'] = '𝟰',
    ['5'] = '𝟱',
    ['6'] = '𝟲',
    ['7'] = '𝟳',
    ['8'] = '𝟴',
    ['9'] = '𝟵'
}
local function translator(input, seg, env)
    local trans_table = alphabet2
    local start_pos = 0
    if string.sub(input, 1, 2) == "\\\\" then
        trans_table = alphabet
        start_pos = 3
    else
        if string.sub(input, 1, 1) == "\\" then
            start_pos = 2
        end
    end
    if start_pos ~= 0 then
        local input2 = string.sub(input, start_pos)
        -- 逐字母替换
        local output = ""
        for i = 1, string.len(input2) do
            local char = string.sub(input2, i, i)
            if trans_table[char] then
                output = output .. trans_table[char]
            else
                output = output .. char
            end
        end
        return yield(Candidate("text", seg.start, seg._end, output, "转"))
    end
    -- if string.sub(input, 1, 1) == "-" then
    --     -- 截取输入的后面部分 
    --     local input2 = string.sub(input, 2)

    --     -- 逐字母替换
    --     local output = ""
    --     for i = 1, string.len(input2) do
    --         local char = string.sub(input2, i, i)
    --         if alphabet[char] then
    --             output = output .. alphabet[char]
    --         else
    --             output = output .. char
    --         end
    --     end
    --     return yield(Candidate("text", seg.start, seg._end, output, "大"))
    -- end
    -- if string.sub(input, 1, 1) == "+" then
    --     -- 截取输入的后面部分 
    --     local input2 = string.sub(input, 2)

    --     -- 逐字母替换
    --     local output = ""
    --     for i = 1, string.len(input2) do
    --         local char = string.sub(input2, i, i)
    --         if alphabet2[char] then
    --             output = output .. alphabet2[char]
    --         else
    --             output = output .. char
    --         end
    --     end
    --     return yield(Candidate("text", seg.start, seg._end, output, "小"))
    -- end

end

return translator
