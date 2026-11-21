-- thumbfast's thumbnails for a stream (network=yes, script-opts/thumbfast.conf). The stream here is one played from
-- the playlist files FastStream's helper wrote (the runner's faststream-mpv-hls-tst001, target.txt beside it): its
-- path is local, its media comes from the network. The thumbnailer starts idle and gets the stream over its pipe,
-- with this mpv's per-file options (the helper's headers and demuxer options) and the lowest HLS bitrate; a local
-- file stays on its command line, as upstream has it. A thumbnail file proves the thumbnailer opened what it got.
-- A private window's stream gets none.
-- The thumbnailer is the runner's mpv.exe (thumbfast-mpv_path, run-tests.ps1).
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

local function options_sent()
	local names = mp.get_property_native('user-data/thumbfast/stream-options')
	return names and table.concat(names, ',') or 'none'
end

-- Hovers the timeline at 5 s, as uosc does, and waits for the thumbnail.
local function thumbnail(name)
	if not last then
		return H.fail(name, 'no thumbfast-info')
	end
	local made = last.thumbnail .. '.bgra'
	os.remove(made)
	mp.commandv('script-message-to', 'thumbfast', 'thumb', '5', '40', '40')
	H.check(
		name,
		H.wait_until(function()
			return utils.file_info(made) ~= nil
		end, 20),
		'no ' .. made
	)
end

H.run(function()
	H.expect('a helper playlist: thumbnails', state, 'on', nil, 5)
	thumbnail('... the thumbnailer opens it from its pipe')
	H.eq('... its own HLS variant, the lowest, at the time hovered', options_sent(), 'hls-bitrate,start,vid')

	mp.del_property('user-data/thumbfast/stream-options')
	last = nil
	H.check('a local file loads', H.load(H.media_path('plain/clip.mkv')))
	H.expect('a local file: thumbnails', state, 'on', nil, 5)
	thumbnail('... the thumbnailer opens it from its command line')
	H.eq('... nothing over the pipe', options_sent(), 'none')

	-- A private window's stream leaves no files behind (faststream-private.lua): no thumbnails. Its fs-private tag
	-- on a copy of the local file, the way FastStream tags a stream's address.
	local private = os.getenv('MPV_TEST_ROOT') .. '/private#fs-content=movie&fs-private=1&x.mkv'
	local src = io.open(H.media_path('plain/clip.mkv'), 'rb')
	local dst = io.open(private, 'wb')
	H.check('a private copy is written', src and dst)
	if src and dst then
		dst:write(src:read('a'))
	end
	if src then
		src:close()
	end
	if dst then
		dst:close()
	end
	last = nil
	H.check('a private stream loads', H.load(private))
	H.expect('... no thumbnails', state, 'off', nil, 5)
	H.sleep(0.5)
	H.eq('... and it stays so', state(), 'off')

	-- As the helper loads it: its headers and demuxer options for this file only (perFileOptions, hlsPlayOptions).
	last = nil
	local restarted = H.expect_event('playback-restart')
	mp.command_native({
		'loadfile',
		H.media_path('faststream-mpv-hls-tst001/0.m3u8'),
		'replace',
		-1,
		{
			['http-header-fields'] = 'Referer: https://a.test/watch?v=1\\,2,User-Agent: Test/1.0',
			demuxer = 'lavf',
			['demuxer-lavf-o'] = 'protocol_whitelist=[file,crypto],format_whitelist=[hls,mpegts]',
		},
	})
	H.check('the helper playlist with its options', restarted(15))
	H.expect('... thumbnails', state, 'on', nil, 5)
	thumbnail('... the thumbnailer opens it with the same options')
	H.eq(
		'... which went over the pipe',
		options_sent(),
		'demuxer,demuxer-lavf-o,hls-bitrate,http-header-fields,start,vid'
	)
	os.remove(private)
end)
