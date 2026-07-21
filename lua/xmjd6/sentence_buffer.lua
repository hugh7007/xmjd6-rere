-- Sentence-mode separator injector.
-- Space and topup append an apostrophe boundary while preserving the complete
-- composition. A second space on an empty segment commits the composition.
local M = {}
local kAccepted, kNoop = 1, 2
local function setof(s) local t={}; for i=1,#tostring(s or '') do t[s:sub(i,i)]=true end; return t end
local function current_chunk(input, separator)
  local sep = separator or "'"
  local pattern = "([^" .. sep .. "]*)$"
  return input:match(pattern) or ''
end
local function should_topup(key, chunk, env)
  if chunk=='' or not env.alphabet[key] then return false end
  if env.protected_codes and env.protected_codes[chunk..key] then return false end
  if env.topup_command and env.topup_set[chunk:sub(1,1)] then return false end
  local prev=chunk:sub(-1); local a,b=env.topup_set[key],env.topup_set[prev]
  local n=utf8.len(chunk) or #chunk
  return (b and not a) or (not b and not a and n>=env.topup_min) or n>=env.topup_max
end
function M.processor(key,env)
  if not key or (key.release and key:release()) then return kNoop end
  local ctx=env and env.engine and env.engine.context
  if not ctx or not ctx:get_option('sentence_mode_enabled') then return kNoop end
  local input=tostring(ctx.input or '')
  -- Read the configured sentence-mode prefix from schema config.
  local config = env and env.engine and env.engine.schema and env.engine.schema.config
  local prefix = "'"
  if config and type(config.get_string) == "function" then
    local ok, value = pcall(function() return config:get_string('sentence_mode/prefix') end)
    if ok and type(value) == "string" and #value == 1 then prefix = value end
  end
  if input:sub(1,1) ~= prefix then return kNoop end
  -- input 恰好是前缀本身时（如单独的 a），不拦截，让主词库翻译出候选
  if #input <= #prefix then return kNoop end
  local repr=key.repr and key:repr() or ''
  local chunk=current_chunk(input, "'")  -- separator inside chunks stays as '
  if repr=='space' then
    if chunk=='' then if ctx.commit then ctx:commit(); return kAccepted end; return kNoop end
    ctx.input=input.."'"; return kAccepted  -- append ' as the internal separator
  end
  local code=tonumber(key.keycode or 0) or 0
  if code>=0x20 and code<0x7f then
    local ch=string.char(code)
    if should_topup(ch,chunk,env) then ctx.input=input.."'"..ch; return kAccepted end
  end
  return kNoop
end
function M.init(env)
  local c=env.engine.schema.config
  env.topup_set=setof(c:get_string('topup/topup_with') or '')
  env.alphabet=setof(c:get_string('speller/alphabet') or 'abcdefghijklmnopqrstuvwxyz')
  env.topup_min=math.max(1,c:get_int('topup/min_length') or 4)
  env.topup_max=math.max(env.topup_min,c:get_int('topup/max_length') or 6)
  env.topup_command=c:get_bool('topup/topup_command')
  local ok,p=pcall(require,'xmjd6.protected_codes'); env.protected_codes=ok and p.load(c) or {}
end
function M.func(a,b) return M.processor(a,b) end
return M
