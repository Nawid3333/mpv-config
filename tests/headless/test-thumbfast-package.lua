-- thumbfast and a stream played from the playlist files FastStream's helper wrote (the runner's
-- faststream-mpv-hls-tst001, target.txt beside it): its path is local, its media comes from the network, and a
-- thumbnail would fetch the stream again without the page's headers. So thumbfast is off for it, as for every
-- network stream (network=no), and on for a local file. thumbfast says so in its thumbfast-info message.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local last = nil
mp.register_script_message('thumbfast-info', function(json)
	last = utils.parse_json(json)
end)

-- "off"/"on" once thumbfast knows the video's size: before that it is off for every file.
local function state()
	if not last or (last.width or 0) == 0 then
		return 'no size yet'
	end
	return last.disabled and 'off' or 'on'
end

H.run(function()
	H.expect('a helper playlist: no thumbnails', state, 'off', nil, 5)
	H.sleep(0.5)
	H.eq('... and it stays so', state(), 'off')
	last = nil
	H.check('a local file loads', H.load(H.media_path('plain/clip.mkv')))
	H.expect('a local file: thumbnails', state, 'on', nil, 5)
	last = nil
	H.check('the helper playlist again', H.load(H.media_path('faststream-mpv-hls-tst001/0.m3u8')))
	H.expect('... no thumbnails again', state, 'off', nil, 5)
	H.sleep(0.5)
	H.eq('... and it stays so', state(), 'off')
end)
