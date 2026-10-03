-- gpu-toggles.lua, process 1 of 2: the Movie sharpness menu's choice is
-- remembered (2026-10-02; it was for the running session only).
-- test-sharpness-restore.lua checks a FRESH process starts with it
-- (AGENTS.md validation item 6a).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	mp.commandv('script-message-to', 'gpu_toggles', 'set-movie-sharpness', '1.5')
	H.sleep(0.3)
	local f = io.open(mp.command_native({ 'expand-path', '~~state/' }) .. '/movie-sharpness.json', 'r')
	local content = f and f:read('*a') or ''
	if f then
		f:close()
	end
	H.check('movie-sharpness.json written with 1.5', content:find('1.5', 1, true) ~= nil, content)
end)
