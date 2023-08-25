local json = require("json")
local http = require("socket.http")
local url = require("socket.url")
http.TIMEOUT = 30


local function translator(input, seg, env)
    local string = env.focus_text
    local reply = http.request('http://suggestion.baidu.com/su?p=1&cb=&ie=UTF-8&action=opensearch&wd=' .. url.escape(string))
    local data = json.decode(reply)
	
	for k, v in ipairs(data[2]) do
		yield(Candidate("translate", seg.start, seg._end, v, " 联想"))
	end

end

return translator