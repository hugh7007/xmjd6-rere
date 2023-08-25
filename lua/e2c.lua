local json = require("json")
local http = require("socket.http")
local url = require("socket.url")
http.TIMEOUT = 3

local function make_url(input)
	return 'http://fanyi.youdao.com/translate?&doctype=json&type=AUTO&i='.. input
end

local function translator(input, seg,env)
    local string = env.focus_text
    local reply = http.request(make_url(string))
    local data = json.decode(reply)

	local c = Candidate("simple", seg.start, seg._end, data.translateResult[1][1].tgt, " 英译汉")
	c.quality = 2
	yield(c)
end

return translator
