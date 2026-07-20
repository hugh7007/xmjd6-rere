-- Switcher-controlled gate for entering sentence mode via configurable prefix key.
-- When sentence mode is OFF, the prefix key (' ) enters the input stream
-- (instead of committing immediately).  Space/Enter will commit it.
-- The prefix key is read from sentence_mode/prefix in schema config.

local kAccepted = 1
local kNoop = 2

local function processor(key_event, env)
    return kNoop
end

return { func = processor }
