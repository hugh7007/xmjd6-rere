-- jieqi_countdown.lua
-- 当候选文本恰好是二十四节气名时，追加倒计时小字。
-- 仅在 /jq 触发的节气候选上生效，其他输入零影响。
-- 使用节气平均公历日期（误差±1天），不依赖 shijian_impl.lua 天文计算。

local JIEQI_DATES = {
  {name="立春",  mon=2,  day=4},
  {name="雨水",  mon=2,  day=19},
  {name="惊蛰",  mon=3,  day=6},
  {name="春分",  mon=3,  day=21},
  {name="清明",  mon=4,  day=5},
  {name="谷雨",  mon=4,  day=20},
  {name="立夏",  mon=5,  day=6},
  {name="小满",  mon=5,  day=21},
  {name="芒种",  mon=6,  day=6},
  {name="夏至",  mon=6,  day=21},
  {name="小暑",  mon=7,  day=7},
  {name="大暑",  mon=7,  day=23},
  {name="立秋",  mon=8,  day=8},
  {name="处暑",  mon=8,  day=23},
  {name="白露",  mon=9,  day=8},
  {name="秋分",  mon=9,  day=23},
  {name="寒露",  mon=10, day=8},
  {name="霜降",  mon=10, day=24},
  {name="立冬",  mon=11, day=7},
  {name="小雪",  mon=11, day=22},
  {name="大雪",  mon=12, day=7},
  {name="冬至",  mon=12, day=22},
  {name="小寒",  mon=1,  day=6},
  {name="大寒",  mon=1,  day=20},
}

local JIEQI_MAP = {}
for _, jq in ipairs(JIEQI_DATES) do
  JIEQI_MAP[jq.name] = jq
end

local M = {}
local cache_date = nil
local cache = {}

local function get_days(name)
  local today = os.date("*t")
  local today_str = os.date("%Y%m%d")
  if cache_date ~= today_str then
    cache_date = today_str
    cache = {}
  end
  if cache[name] ~= nil then return cache[name] end

  local jq = JIEQI_MAP[name]
  if not jq then return nil end

  local now = os.time()
  local year = today.year

  local best_diff = nil
  for _, y in ipairs({year - 1, year, year + 1}) do
    local t = os.time({year=y, month=jq.mon, day=jq.day, hour=12})
    local diff = math.floor((t - now) / 86400 + 0.5)
    if diff >= 0 and (best_diff == nil or diff < best_diff) then
      best_diff = diff
    end
  end

  if best_diff then
    cache[name] = best_diff
  else
    cache[name] = -1
  end
  return cache[name]
end

function M.func(input, env)
  for cand in input:iter() do
    local text = cand.text
    -- 只匹配纯节气名或 "节气名 YYYY-MM-DD" 格式（jq 分支输出）
    -- 不匹配 "农历日期-节气名" 格式（rq/nl 分支），因为 JQtest 返回当前节气，倒计时语义不一致
    local matched_name = nil
    if JIEQI_MAP[text] then
      matched_name = text
    else
      local name = text:match("^(.-)%s+%d%d%d%d%-%d%d%-%d%d$")
      if name and JIEQI_MAP[name] then
        matched_name = name
      end
    end
    if matched_name then
      local days = get_days(matched_name)
      if days and days >= 0 then
        local tip
        if days == 0 then
          tip = "< 今天"
        else
          tip = "< " .. days .. "天"
        end
        -- 保留原注释，追加倒计时
        local orig_comment = cand.comment or ""
        local new_comment = orig_comment
        if orig_comment and orig_comment ~= "" then
          new_comment = orig_comment .. " " .. tip
        else
          new_comment = tip
        end
        yield(Candidate("jqcd", cand.start, cand._end, text, new_comment))
      else
        yield(cand)
      end
    else
      yield(cand)
    end
  end
end

return M
