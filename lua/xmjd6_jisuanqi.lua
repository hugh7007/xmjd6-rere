-- Rime Script >https://github.com/baopaau/rime-lua-collection/blob/master/calculator_translator.lua
-- 计算器适配版，此版本经过二次优化 
-- 作者：@浮生 https://github.com/wzxmer/rime-txjx
-- 更新：2026-02-21
-- 簡易計算器（執行任何Lua表達式）
-- 优化说明：高级数学函数(微积分、统计)改为延迟加载，节省内存；使用沙盒环境增强安全性和性能。
--
-- 格式：=<exp>
-- Lambda語法糖：\<arg>.<exp>|
--
-- 例子：
-- =1+1 輸出 2
-- =floor(9^(8/7)*cos(deg(6))) 輸出 -3
-- =e^pi>pi^e 輸出 true
-- =max({1,7,2}) 輸出 7
-- =map({1,2,3},\x.x^2|) 輸出 {1, 4, 9}
-- =map(range(-5,5),\x.x*pi/4|,deriv(sin)) 輸出 {-0.7071, -1, -0.7071, 0, 0.7071, 1, 0.7071, 0, -0.7071, -1}
-- =$(range(-50,50))(map,\x.x/100|,\x.-60*x^2-16*x+20|)(max)() 輸出 21.066

-- 需在方案增加 `recognizer/patterns/expression: "^=.*$"`

-- # 环境构建 (Sandbox Env)
-- 将所有可用函数放入 Env 表中，load 时直接使用此表作为环境，无需每次定义局部变量，且天然隔离 unsafe 函数。

local Env = {}

-- 注入 math 库所有函数到顶层 (sin, cos, floor, etc.)
for k, v in pairs(math) do
  Env[k] = v
end
Env.abs = math.abs -- 确保常用函数存在
Env.mod = math.fmod

-- 补充常量
Env.inf = math.huge
Env.e = math.exp(1)
Env.pi = math.pi

-- 基础 Helper 函数
Env.trunc = function (x, dc)
  if dc == nil then
    return math.modf(x)
  end
  return x - Env.mod(x, dc)
end

Env.round = function (x, dc)
  dc = dc or 1
  local dif = Env.mod(x, dc)
  if math.abs(dif) > dc / 2 then
    return x < 0 and x - dif - dc or x - dif + dc
  end
  return x - dif
end

Env.log = function (x, base)
  base = base or 10
  return math.log(x)/math.log(base)
end

Env.isinteger = function (x)
  return math.fmod(x, 1) == 0
end

-- 数组/迭代器 Helper
Env.array = function (...)
  local arr = {}
  for v in ... do
    arr[#arr + 1] = v
  end
  return arr
end

local irange = function (from,to)
  if to == nil then
    to = from
    from = 0
  end
  local i = from - 1
  to = to - 1
  return function()
    if i < to then
      i = i + 1
      return i
    end
  end
end
Env.irange = irange

Env.range = function (from, to)
  return Env.array(irange(from, to))
end

local irev = function (arr)
  local i = #arr + 1
  return function()
    if i > 1 then
      i = i - 1
      return arr[i]
    end
  end
end
Env.irev = irev

Env.arev = function (arr)
  return Env.array(irev(arr))
end

Env.min = function (arr)
  local m = Env.inf
  for k, x in ipairs(arr) do
   m = x < m and x or m
  end
  return m
end

Env.max = function (arr)
  local m = -Env.inf
  for k, x in ipairs(arr) do
   m = x > m and x or m
  end
  return m
end

Env.sum = function (t)
  local acc = 0
  for k,v in ipairs(t) do
    acc = acc + v
  end
  return acc
end

Env.avg = function (t)
  return Env.sum(t) / #t
end

-- Functional Helpers
Env.map = function (t, ...)
  local ta = {}
  for k,v in pairs(t) do
    local tmp = v
    for _,f in pairs({...}) do tmp = f(tmp) end
    ta[k] = tmp
  end
  return ta
end

Env.filter = function (t, ...)
  local ta = {}
  local i = 1
  for k,v in pairs(t) do
    local erase = false
    for _,f in pairs({...}) do
      if not f(v) then
        erase = true
        break
      end
    end
    if not erase then
	  ta[i] = v
	  i = i + 1
    end
  end
  return ta
end

Env.foldr = function (t, f, val)
  for k,v in pairs(t) do
    val = f(val, v)
  end
  return val
end

Env.foldl = function (t, f, val)
  for v in irev(t) do
    val = f(val, v)
  end
  return val
end

Env.chain = function (t)
  local ta = t
  local function cf(f, ...)
    if f ~= nil then
      ta = f(ta, ...)
      return cf
    else
      return ta
    end
  end
  return cf
end

-- Statistics
Env.fac = function (n)
  local acc = 1
  for i = 2,n do
    acc = acc * i
  end
  return acc
end

Env.nPr = function (n, r)
  return Env.fac(n) / Env.fac(n - r)
end

Env.nCr = function (n, r)
  return Env.nPr(n,r) / Env.fac(r)
end

Env.MSE = function (t)
  local ss = 0
  local s = 0
  local n = #t
  for k,v in ipairs(t) do
    ss = ss + v*v
    s = s + v
  end
  return math.sqrt((n*ss - s*s) / (n*n))
end

-- Safe OS functions
Env.date = os.date
Env.time = os.time

-- # Calculus (优化：延迟加载，注入到 Env 中)
local function load_calculus()
    if Env.deriv then return end

    local lapproxd = function (f, delta)
      local delta = delta or 1e-8
      return function (x)
               return (f(x+delta) - f(x)) / delta
             end
    end

    local sapproxd = function (f, delta)
      local delta = delta or 1e-8
      return function (x)
               return (f(x+delta) - f(x-delta)) / delta / 2
             end
    end

    Env.deriv = function (f, delta, dc)
      dc = dc or 1e-4
      local fd = sapproxd(f, delta)
      return function (x)
               return Env.round(fd(x), dc)
             end
    end

    local trapzo = function (f, a, b, n)
      local dif = b - a
      local acc = 0
      for i = 1, n-1 do
        acc = acc + f(a + dif * (i/n))
      end
      acc = acc * 2 + f(a) + f(b)
      acc = acc * dif / n / 2
      return acc
    end

    Env.integ = function (f, delta, dc)
      delta = delta or 1e-4
      dc = dc or 1e-4
      return function (a, b)
               if b == nil then
                 b = a
                 a = 0
               end
               local n = Env.round(math.abs(b - a) / delta)
               return Env.round(trapzo(f, a, b, n), dc)
             end
    end

    Env.rk4 = function (f, timestep)
      local timestep = timestep or 0.01
      return function (start_x, start_y, time)
               local x = start_x
               local y = start_y
               local t = time
               for i = 0, t, timestep do
                 local k1 = f(x, y)
                 local k2 = f(x + (timestep/2), y + (timestep/2)*k1)
                 local k3 = f(x + (timestep/2), y + (timestep/2)*k2)
                 local k4 = f(x + timestep, y + timestep*k3)
                 y = y + (timestep/6)*(k1 + 2*k2 + 2*k3 + k4)
                 x = x + timestep
               end
               return y
             end
    end
end

-- # System & Output formatting

local function serialize(obj)
  local type = type(obj)
  if type == "number" then
    return Env.isinteger(obj) and math.floor(obj) or obj
  elseif type == "boolean" then
    return tostring(obj)
  elseif type == "string" then
    return '"'..obj..'"'
  elseif type == "table" then
    local parts = {"{"}
    local i = 1
    for k, v in pairs(obj) do
      if i ~= k then
        parts[#parts + 1] = "["..serialize(k).."]="
      end
      parts[#parts + 1] = serialize(v)
      parts[#parts + 1] = ", "
      i = i + 1
    end
    if #parts > 1 then parts[#parts] = nil end
    parts[#parts + 1] = "}"
    return table.concat(parts)
  elseif type(obj) == "function" then
    return "callable"
  end
  return obj
end

local greedy = true

-- # 金额转换函数（延迟加载优化）
local speakMoney_cached

local function load_money_functions()
    if speakMoney_cached then return speakMoney_cached end

    local function splitNumStr(str)
        local part = {}
        part.sym, part.int, part.dig, part.dec = string.match(str, "^([%+%-]?)(%d*)(%.?)(%d*)")
        return part
    end

    local defaultValMap = {
        [0] = "零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
        ["+"] = "正", ["-"] = "负", ["."] = "点", [""] = ""
    }
    local defaultPosMap4 = {[1]="仟"; [2]="佰"; [3]="拾"; [4]=""}
    local defaultValMap10 = {[0]="零"; "一"; "二"; "三" ;"四"; "五"; "六"; "七"; "八"; "九"}
    local defaultPosMap_int = { [1] = "千",[2] = "百",[3] = "十",[4] = "" }

    local function speakLiterally(str, valMap)
        valMap = valMap or defaultValMap
        local tbOut = {}
        for k = 1, #str do
            local v = string.sub(str, k, k)
            v = tonumber(v) or v
            tbOut[k] = valMap[v]
        end
        return table.concat(tbOut)
    end

    local function speakBar(str, posMap, valMap)
        posMap = posMap or defaultPosMap4
        valMap = valMap or defaultValMap10

        local out = ""
        local bar = string.sub("****" .. str, -4, -1)
        for pos = 1, 4 do
            local val = tonumber(string.sub(bar, pos, pos))
            if val == nil then goto continue end
            if val > 0 then
                out = out .. valMap[val] .. posMap[pos]
                goto continue
            end
            local valNext = tonumber(string.sub(bar, pos+1, pos+1))
            if ( valNext==nil or valNext==0 )then
                goto continue
            else
                out = out .. valMap[0]
                goto continue
            end
        ::continue::
        end
        if out == "" then out = valMap[0] end
        return out
    end

    local function speakIntOfficially(str, posMap, valMap)
        posMap = posMap or defaultPosMap_int
        valMap = valMap or defaultValMap10

        local int = string.match(str, "^0*(%d+)$")
        if int == "" then int = "0" end
        local remain = #int % 4
        if remain == 0 then remain = 4 end
        local tbBar = { [1] = string.sub(int, 1, remain) }
        for pos = remain + 1, #int, 4 do
            local bar = string.sub(int, pos, pos + 3)
            table.insert(tbBar, bar)
        end
        local tbSpeakBarSuffix = { [1] = "" }
        for iBar = 2, #tbBar do
            local suffix = (iBar % 2 == 0) and ("万" .. tbSpeakBarSuffix[1]) or ("亿" .. tbSpeakBarSuffix[2])
            table.insert(tbSpeakBarSuffix, 1, suffix)
        end
        local tbSpeakBar = {}
        for k = 1, #tbBar do
            tbSpeakBar[k] = speakBar(tbBar[k], posMap, valMap)
        end
        local out = ""
        for k = 1, #tbBar do
            local speakBar = tbSpeakBar[k]
            if speakBar ~= valMap[0] then
                out = out .. speakBar .. tbSpeakBarSuffix[k]
            end
        end
        if out == "" then out = valMap[0] end
        return out
    end

    local function speakDecMoney(str, posMap, valMap)
        posMap = posMap or {[1]="角"; [2]="分"; [3]="厘"; [4]="毫"}
        valMap = valMap or {[0]="零"; "壹"; "贰"; "叁" ;"肆"; "伍"; "陆"; "柒"; "捌"; "玖"}

        local dec = string.sub(str, 1, 4)
        dec = string.gsub(dec, "0*$", "")
        if dec == "" then return "整" end

        local out = ""
        for pos = 1, #dec do
            local val = tonumber(string.sub(dec, pos, pos))
            out = out .. valMap[val] .. posMap[pos]
        end
        return out
    end

    local function speakMoney(str)
        local part = splitNumStr(str)
        if not part.int then return str end
        local speakSym = speakLiterally(part.sym)
        local speakInt = speakIntOfficially(part.int, { [1] = "仟",[2] = "佰",[3] = "拾",[4] = "" },
        { [0] = "零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖" }) .. "元"
        local speakDec = speakDecMoney(part.dec)
        local out = speakSym .. speakInt .. speakDec
        return out
    end

    speakMoney_cached = speakMoney
    return speakMoney
end



local function calculator_translator(input, seg, env)
  local ctx = env and env.engine and env.engine.context
  if ctx and ctx.get_option and not ctx:get_option("jisuanqi") then return end
  if string.sub(input, 1, 1) ~= "=" then return end
  
  -- 原有的 // 处理逻辑被移除，因为存在死代码问题且逻辑不明

  local expfin = greedy or string.sub(input, -1, -1) == ";"
  local exp = (greedy or not expfin) and string.sub(input, 2, -1) or string.sub(input, 2, -2)
  
  exp = exp:gsub("#", " ")
  
  if not expfin then return end
  
  local expe = exp
  expe = expe:gsub("%$", " chain ")
  
  -- lambda parser
  do
    local count
    repeat
      expe, count = expe:gsub("\\%s*([%a%d%s,_]-)%s*%.(.-)|", " (function (%1) return %2 end) ")
    until count == 0
  end
  
  -- 按需加载微积分
  if expe:find("deriv") or expe:find("integ") or expe:find("rk4") then
    load_calculus()
  end

  -- 安全执行：使用 Env 沙盒
  -- 注意：load 的环境参数在 Lua 5.2+ 中支持。Rime 通常使用较新 Lua。
  -- 如果环境不支持，这里可能需要回退，但 Env 方案是最优解。
  local func, load_err
  if _VERSION >= "Lua 5.2" then
      func, load_err = load("return "..expe, "calc", "t", Env)
  else
      -- Fallback for Lua 5.1 / LuaJIT
      func, load_err = loadstring("return "..expe)
      if func then setfenv(func, Env) end
  end

  if not func then return end
  
  local success, result = pcall(func)
  if not success or result == nil then return end
  
  local resultStr = serialize(result)
  yield(Candidate("number", seg.start, seg._end, exp.."="..resultStr, "等式", "123"))
  yield(Candidate("number", seg.start, seg._end, resultStr, "答案"))

  -- 优化：只有结果为数字时才延迟加载金额转换函数
  if type(result) == "number" then
      local speakMoney = load_money_functions()
      yield(Candidate("number", seg.start, seg._end, speakMoney(resultStr), "金额"))
  end
end

local function fini(env)
end

return { func = calculator_translator, fini = fini }
