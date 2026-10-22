-- yt-dlp's JavaScript runtime (settings.lua). mpv.conf has yt-dlp solve YouTube's challenges
-- with Node.js (js-runtimes=node), which yt-dlp looks for on PATH; the one-click install keeps
-- its FastStream helper's node.exe private, on no PATH, so a PC without a Node.js of its own got
-- no runtime at all. The runner gives each process a LOCALAPPDATA of its own: phase 'none' has
-- no private node.exe in it, phase 'private' has one (a stand-in file).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local phase = os.getenv('MPV_TEST_PHASE')

H.run(function()
	local raw = mp.get_property_native('options/ytdl-raw-options') or {}
	if phase == 'private' then
		local node = os.getenv('LOCALAPPDATA') .. '\\FastStreamMpvHost\\node\\node.exe'
		H.eq('yt-dlp is pointed at the private node.exe', raw['js-runtimes'], 'node:' .. node)
	else
		H.eq("without one, mpv.conf's Node.js on PATH stays", raw['js-runtimes'], 'node')
	end
end)
