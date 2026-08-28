-- shape_lookup.lua
-- 以形查字（不念拼音）：`` + 形码，或 o + 形码 → 在所有“以该形码结尾”的键道码里找字
--                        （o 不需要音韵，只打基础笔画/形码即可）
--
-- 触发：输入以反引号 ` 开头（tag=shape_lookup），或以 o 开头（tag=xmjd6gbk），
--       分别由 schema 的 recognizer/patterns 的 shape_lookup 与 xmjd6gbk 路由到本翻译器。
-- 查表：xmjd6.cx.dict.yaml（键道码字典，键为 音+韵+形… ，形在码尾）。
-- 关键点：Rime 原生的 reverse_lookup_translator 只能“从码头前缀匹配”，而形码在码尾，
--         所以这里用 Lua 做“码尾匹配（后缀匹配）”，从而实现只打后面几个形就能出字。
--         候选注释自带「编码在前、拼音在后」格式（如 `wda [chǒu]`），拼音从字典 # 〔…〕 注释解析，
--         `` ` `` 与 o 一致，不依赖 cx_pinyin_hint 过滤器，确保“后面的小字”里始终有拼音。

local dict_name = "xmjd6.cx.dict.yaml"
local MAX_CANDIDATES = 80

local function path_separator()
  if package and package.config then
    return package.config:sub(1, 1)
  end
  return "/"
end

local function join_path(dir, name)
  if not dir or dir == "" then return name end
  local sep = path_separator()
  if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
    return dir .. name
  end
  return dir .. sep .. name
end

local function user_data_dir()
  if rime_api and rime_api.get_user_data_dir then
    local ok, dir = pcall(rime_api.get_user_data_dir)
    if ok and dir and dir ~= "" then return dir end
  end
  return "."
end

-- entries: 全部 {text=字, code=键道码}
-- by_last: 以码的最后一位字符为索引的候选桶，用于加速查询
local entries = nil
local by_last = nil

local function load_entries()
  entries = {}
  by_last = {}
  local f = io.open(join_path(user_data_dir(), dict_name), "r")
  if not f then return end
  for line in f:lines() do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      -- 行格式：字\t码\tweight # 〔拼音〕
      local text, rest = line:match("^([^\t]+)\t(.+)$")
      if text and rest then
        local code = rest:match("^%S+")            -- 第一个空白前的记号即键道码
        local py = rest:match("〔([^〕]*)〕")        -- 末尾 〔拼音〕 注释
        if code then
          local e = { text = text, code = code, py = py or "" }
          entries[#entries + 1] = e
          local last = code:sub(-1)
          by_last[last] = by_last[last] or {}
          by_last[last][#by_last[last] + 1] = e
        end
      end
    end
  end
  f:close()
end

local function init(env)
  load_entries()
end

local function func(input, seg, env)
  -- 同时服务两种“以形查字”入口：
  --   - `` ` `` 前缀（tag=shape_lookup）：输入含反引号，去掉反引号即得形码
  --   - o 前缀（tag=xmjd6gbk）：输入以 o 开头，去掉前缀 o 即得形码（不需要音韵）
  local is_o = seg:has_tag("xmjd6gbk")
  if not seg:has_tag("shape_lookup") and not is_o then return end
  if not entries then load_entries() end
  if not entries or #entries == 0 then return end

  -- 归一化形码：`` ` `` 去反引号；o 去前缀 o；统一小写
  local q
  if is_o then
    q = input:gsub("^o", ""):lower()
  else
    q = input:gsub("`", ""):lower()
  end
  if q == "" then return end

  local n = #q
  local bucket = by_last[q:sub(-1)] or {}
  local results = {}
  for i = 1, #bucket do
    local e = bucket[i]
    local cl = #e.code
    if cl >= n and e.code:sub(cl - n + 1) == q then
      results[#results + 1] = e
    end
  end

  -- 排序：码越短越靠前（越接近“只此形码”），同长度按字
  table.sort(results, function(a, b)
    if #a.code ~= #b.code then return #a.code < #b.code end
    return a.text < b.text
  end)

  local limit = math.min(#results, MAX_CANDIDATES)
  for i = 1, limit do
    local e = results[i]
    -- 注释：编码在前、拼音在后（拼音用 [ ] 括起，从字典 # 〔…〕 注释解析，本翻译器自带，`` ` `` 与 o 一致）
    local comment = e.code
    if e.py and e.py ~= "" then
      comment = e.code .. " [" .. e.py .. "]"
    end
    local cand = Candidate("shape", seg.start, seg._end, e.text, comment)
    cand.quality = 1000 - i
    yield(cand)
  end
end

return { init = init, func = func }
