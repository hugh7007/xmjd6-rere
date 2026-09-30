-- text_utils.lua
-- 纯文本转换 translator 合集（合并自 zimu.lua / unicode.lua / xmjd6_shuzi.lua）
--
-- 三个组件都是"输入某种前缀 → 产出文本候选"的 translator，没有任何共享状态、
-- 没有 require 依赖、也没有额外初始化，因此合并成本为零。
-- 与 librime-lua 的 `lua_translator@*xmjd6/text_utils@<名字>` 配合使用：
-- 每个 schema 挂载点用不同的 @name_space 选中对应函数。
--
-- 拼装规则（来自 librime-lua 的 load_module）：
--   模块里的函数若名为 M.<name>，则 @<name> 取到它；
--   否则退化为 @<name_space>（schema 里 @ 后的那一段）。
-- 这里一律用 @zimu / @unicode / @shuzi 显式指定，避免依赖退化行为。

local M = {}

-- =====================================================================
-- 第一部分：zimu（原 zimu.lua）
-- \abc → 𝒂𝒃𝒄（粗斜体）；\\abc → 𝑨𝑩𝑪（粗正体）；\\\abc → 𝗔𝗕𝗖（sans 粗体）
-- =====================================================================
local ZIMU_ALPHABET = {
    a = '𝑨', b = '𝑩', c = '𝑪', d = '𝑫', e = '𝑬', f = '𝑭', g = '𝑮', h = '𝑯',
    i = '𝑰', j = '𝑱', k = '𝑲', l = '𝑳', m = '𝑴', n = '𝑵', o = '𝑶', p = '𝑷',
    q = '𝑸', r = '𝑹', s = '𝑺', t = '𝑻', u = '𝑼', v = '𝑽', w = '𝑾', x = '𝑿',
    y = '𝒀', z = '𝒁',
    ['0'] = '𝟬', ['1'] = '𝟭', ['2'] = '𝟮', ['3'] = '𝟯', ['4'] = '𝟰',
    ['5'] = '𝟱', ['6'] = '𝟲', ['7'] = '𝟳', ['8'] = '𝟴', ['9'] = '𝟵',
}

local ZIMU_ALPHABET2 = {
    a = '𝒂', b = '𝒃', c = '𝒄', d = '𝒅', e = '𝒆', f = '𝒇', g = '𝒈', h = '𝒉',
    i = '𝒊', j = '𝒋', k = '𝒌', l = '𝒍', m = '𝒎', n = '𝒏', o = '𝒐', p = '𝒑',
    q = '𝒒', r = '𝒓', s = '𝒔', t = '𝒕', u = '𝒖', v = '𝒗', w = '𝒘', x = '𝒙',
    y = '𝒚', z = '𝒛',
    ['0'] = '𝟶', ['1'] = '𝟷', ['2'] = '𝟸', ['3'] = '𝟹', ['4'] = '𝟺',
    ['5'] = '𝟻', ['6'] = '𝟼', ['7'] = '𝟽', ['8'] = '𝟾', ['9'] = '𝟿',
}

local ZIMU_ALPHABET3 = {
    a = '𝗔', b = '𝗕', c = '𝗖', d = '𝗗', e = '𝗘', f = '𝗙', g = '𝗚', h = '𝗛',
    i = '𝗜', j = '𝗝', k = '𝗞', l = '𝗟', m = '𝗠', n = '𝗡', o = '𝗢', p = '𝗣',
    q = '𝗤', r = '𝗥', s = '𝗦', t = '𝗧', u = '𝗨', v = '𝗩', w = '𝗪', x = '𝗫',
    y = '𝗬', z = '𝗭',
    ['0'] = '𝟬', ['1'] = '𝟭', ['2'] = '𝟮', ['3'] = '𝟯', ['4'] = '𝟰',
    ['5'] = '𝟱', ['6'] = '𝟲', ['7'] = '𝟳', ['8'] = '𝟴', ['9'] = '𝟵',
}

function M.zimu(input, seg, env)
    local trans_table = ZIMU_ALPHABET2
    local start_pos = 0
    if string.sub(input, 1, 3) == "\\\\\\" then
        start_pos = 4
        trans_table = ZIMU_ALPHABET3
    elseif string.sub(input, 1, 2) == "\\\\" then
        trans_table = ZIMU_ALPHABET
        start_pos = 3
    elseif string.sub(input, 1, 1) == "\\" then
        start_pos = 2
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
end

-- =====================================================================
-- 第二部分：unicode（原 unicode.lua）
-- U62fc / &62fc → 「拼」；另有 16 个同前缀码位的补充候选
-- =====================================================================
function M.unicode(input, seg, env)
    local ucodestr = seg:has_tag("unicode") and (input:match("&(%x+)") or input:match("u(%x+)"))
    if ucodestr and #ucodestr > 1 then
        local code = tonumber(ucodestr, 16)
        local text = utf8.char(code)
        yield(Candidate("unicode", seg.start, seg._end, text, string.format("u%x", code)))
        if code < 0x10000 then
            for i = 0, 15 do
                local text2 = utf8.char(code * 16 + i)
                yield(Candidate("unicode", seg.start, seg._end, text2, string.format("u%x~%x", code, i)))
            end
        end
    end
end

-- =====================================================================
-- 第三部分：shuzi（原 xmjd6_shuzi.lua）
-- =abcd 阿拉伯数字 → 大小写汉字四种写法
-- =====================================================================
local SHUZI_CONFS = {
   {
      comment = " 大写",
      number = { [0] = "零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖" },
      suffix = { [0] = "", "拾", "佰", "仟" },
      suffix2 = { [0] = "", "万", "亿", "万亿", "亿亿" }
   },
   {
      comment = " 小写",
      number = { [0] = "零", "一", "二", "三", "四", "五", "六", "七", "八", "九" },
      suffix = { [0] = "", "十", "百", "千" },
      suffix2 = { [0] = "", "万", "亿", "万亿", "亿亿" }
   },
   {
      comment = " 大寫",
      number = { [0] = "零", "壹", "貳", "參", "肆", "伍", "陸", "柒", "捌", "玖" },
      suffix = { [0] = "", "拾", "佰", "仟" },
      suffix2 = { [0] = "", "萬", "億", "萬億", "億億" }
   },
   {
      comment = " 小寫",
      number = { [0] = "零", "一", "二", "三", "四", "五", "六", "七", "八", "九" },
      suffix = { [0] = "", "十", "百", "千" },
      suffix2 = { [0] = "", "萬", "億", "萬億", "億億" }
   },
}

local function shuzi_read_seg(conf, n)
   local s = ""
   local i = 0
   local zf = true

   while string.len(n) > 0 do
      local d = tonumber(string.sub(n, -1, -1))
      if d ~= 0 then
         s = conf.number[d] .. conf.suffix[i] .. s
         zf = false
      else
         if not zf then
            s = conf.number[0] .. s
         end
         zf = true
      end
      i = i + 1
      n = string.sub(n, 1, -2)
   end

   return i < 4, s
end

local function shuzi_read_number(conf, n)
   local s = ""
   local i = 0
   local zf = false

   n = string.gsub(n, "^0+", "")

   if n == "" then
      return conf.number[0]
   end

   while string.len(n) > 0 do
      local zf2, r = shuzi_read_seg(conf, string.sub(n, -4, -1))
      if r ~= "" then
         if zf and s ~= "" then
            s = r .. conf.suffix2[i] .. conf.number[0] .. s
         else
            s = r .. conf.suffix2[i] .. s
         end
      end
      zf = zf2
      i = i + 1
      n = string.sub(n, 1, -5)
   end
   return s
end

function M.shuzi(input, seg, env)
   if string.sub(input, 1, 1) == "=" then
      local n = string.sub(input, 2)
      if tonumber(n) ~= nil then
         for _, conf in ipairs(SHUZI_CONFS) do
            local r = shuzi_read_number(conf, n)
            yield(Candidate("number", seg.start, seg._end, r, conf.comment))
         end
      end
   end
end

-- ════════════════════════════════════════════════════════════════
-- 导出：librime-lua 的 raw_init 一律硬取 .func，@ 后缀只落进 env.name_space
-- 供模块内自行分流（不会用来选函数）。因此三个组件共用一个 .func，
-- 由 env.name_space 决定走哪一路。
--   lua_translator@*xmjd6/text_utils@zimu     → env.name_space == "zimu"
--   lua_translator@*xmjd6/text_utils@shuzi    → env.name_space == "shuzi"
--   lua_translator@*xmjd6/text_utils@unicode  → env.name_space == "unicode"
-- ════════════════════════════════════════════════════════════════
local NAME_SPACE_FUNCS = {
    zimu = M.zimu,
    shuzi = M.shuzi,
    unicode = M.unicode,
}

function M.func(input, seg, env)
    local ns = env and env.name_space
    -- name_space 实测为 "zimu" 这种纯名字（schema 里 @ 后那一段）。
    -- 兼容万一被拼成 "*xmjd6/text_utils@zimu" 的情况：统一取 @ 后 / 末尾名字。
    local key = nil
    if type(ns) == "string" then
        key = ns:match("@([%w_]+)$") or ns:match("^([%w_]+)$")
    end
    local fn = key and NAME_SPACE_FUNCS[key]
    if fn then
        return fn(input, seg, env)
    end
    -- 没写 @ 或名字不认识时：按输入形式兜底挑选，保证组件仍可用
    if type(input) ~= "string" then return end
    if input:match("^=") then
        return M.shuzi(input, seg, env)
    end
    if seg:has_tag("unicode") and (input:match("&%x+") or input:match("u%x+")) then
        return M.unicode(input, seg, env)
    end
    return M.zimu(input, seg, env)
end

return M
