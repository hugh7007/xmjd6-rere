-- app_launcher.lua
-- Cross-platform desktop application launcher for Rime.
--
-- Usage:
--   =oc  Calculator
--   =ol  Calendar
--   =os  System Settings
--   =on  Notes / Notepad
--   =ot  Terminal / Command Prompt
--   =of  Finder / Explorer
--
-- The app opens immediately when an exact code is typed.

local M = {}

local kAccepted = 1
local kNoop = 2

M.prefix = "=o"

M.apps = {
    c = {
        code = "c",
        name = "Calculator",
        comment = "open calculator",
        commands = {
            macos = "open -a Calculator",
            windows = 'cmd /c start "" calc.exe',
        },
    },
    l = {
        code = "l",
        name = "Calendar",
        comment = "open calendar",
        commands = {
            macos = "open -a Calendar",
            windows = 'cmd /c start "" outlookcal:',
        },
    },
    s = {
        code = "s",
        name = "System Settings",
        comment = "open system settings",
        commands = {
            macos = 'open "x-apple.systempreferences:"',
            windows = 'cmd /c start "" ms-settings:',
        },
    },
    n = {
        code = "n",
        name = "Notes / Notepad",
        comment = "open notes",
        commands = {
            macos = "open -a Notes",
            windows = 'cmd /c start "" notepad.exe',
        },
    },
    t = {
        code = "t",
        name = "Terminal",
        comment = "open terminal",
        commands = {
            macos = "open -a Terminal",
            windows = 'cmd /c start "" cmd.exe',
        },
    },
    f = {
        code = "f",
        name = "Finder / Explorer",
        comment = "open file manager",
        commands = {
            macos = "open ~",
            windows = 'cmd /c start "" explorer.exe',
        },
    },
}

M.order = { "c", "l", "s", "n", "t", "f" }

function M.detect_platform()
    local config = package.config or ""
    if config:sub(1, 1) == "\\" then
        return "windows"
    end

    local ok, pipe = pcall(io.popen, "uname -s 2>/dev/null")
    if ok and pipe then
        local name = pipe:read("*l") or ""
        pipe:close()
        if name == "Darwin" then
            return "macos"
        end
    end

    return "unsupported"
end

function M.lookup(input)
    if type(input) ~= "string" then
        return nil
    end

    local code = input:match("^=o([a-z0-9]+)$")
    if not code then
        return nil
    end

    return M.apps[code]
end

function M.command_for(app, platform)
    if not app or not app.commands then
        return nil
    end

    if platform == "darwin" or platform == "mac" then
        platform = "macos"
    elseif platform == "win" then
        platform = "windows"
    end

    return app.commands[platform]
end

function M.launch(input, platform, execute_fn)
    local app = M.lookup(input)
    if not app then
        return false, nil, nil, "unknown_code"
    end

    platform = platform or M.detect_platform()
    local command = M.command_for(app, platform)
    if not command then
        return false, app, nil, "unsupported_platform"
    end

    execute_fn = execute_fn or os.execute
    local ok = pcall(execute_fn, command)
    if not ok then
        return false, app, command, "execute_failed"
    end

    return true, app, command
end

local function key_to_char(key)
    local ch = key and key.keycode
    if not ch or ch < 0x20 or ch >= 0x7f then
        return nil
    end
    return string.char(ch)
end

function M.processor(key, env)
    if not key or key:release() or key:ctrl() or key:alt() or key:super() then
        return kNoop
    end

    local context = env and env.engine and env.engine.context
    if not context then
        return kNoop
    end

    local ch = key_to_char(key)
    if not ch then
        return kNoop
    end

    -- Processor runs before speller appends the current key.  Launch when
    -- the current key completes a whitelisted code, e.g. input "=o" + "l".
    local next_input = (context.input or "") .. ch
    if not M.lookup(next_input) then
        return kNoop
    end

    local ok = M.launch(next_input)
    if ok then
        context:clear()
        return kAccepted
    end

    return kNoop
end

local function make_candidate(seg, text, comment, quality)
    local cand = Candidate("app_launcher", seg.start, seg._end, text, comment)
    cand.quality = quality or 100000
    return cand
end

function M.translator(input, seg, env)
    if input == M.prefix then
        for i, code in ipairs(M.order) do
            local app = M.apps[code]
            if app then
                yield(make_candidate(seg, M.prefix .. code, "open " .. app.name, 99990 - i))
            end
        end
        return
    end

    local app = M.lookup(input)
    if not app then
        return
    end

    local platform = M.detect_platform()
    local command = M.command_for(app, platform)
    local comment = command and "auto opens when typed" or "unsupported platform"
    yield(make_candidate(seg, "Open: " .. app.name, comment, 100000))
end

function M.func(first, second, third)
    if type(first) == "string" then
        return M.translator(first, second, third)
    end
    return M.processor(first, second)
end

return M

