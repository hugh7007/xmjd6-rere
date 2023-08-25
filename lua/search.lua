local url = require("socket.url")

local function translator(input, seg, env)
    local string = env.focus_text

    local strCmd = 'start "Internet Explorer" ' .. '"https://www.baidu.com/s?wd=' .. url.escape(string) .. '"'
	
	local file = io.open('111222333555.txt', 'w')
	io.output(file)
	io.write('' .. strCmd .. '')
	io.close()


    os.execute(strCmd)
end

return translator
