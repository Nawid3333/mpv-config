-- Scripts/percent-seek.lua: the number keys jump from the buffer when it holds the spot.
-- mpv's own percent seek asks the demuxer for a fraction of the file on HLS and MPEG-TS
-- sources, which never uses the demuxer cache: a jump into buffered video read it all
-- again. demuxer-cache-state's debug-low-level-seeks counts the demuxer's own seeks; a
-- jump served by the cache adds none (a jump into the range being read needs no resume
-- of the demuxer either). Two processes (tests/run-tests.ps1, "percent-seek"):
--   hls - variants/v180.m3u8 (one 20 s segment, read whole at once): 5, 9 and 0 come
--         from the buffer, and it stays one range.
--   ts  - ts/long.ts (180 s, MPEG-TS) read only ~6 s ahead (demuxer-max-bytes 512 KiB,
--         set after stream-buffer.lua's own): 5 lies outside the buffer and stays mpv's
--         percent seek; once the rest is read, 7 comes from the buffer, and 0 too, from
--         the first range, kept beside the new one.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local PHASE = os.getenv('MPV_TEST_PHASE') or 'hls'

if PHASE == 'ts' then
	-- after stream-buffer.lua's on_load (priority 50), which sets the local file's limits
	mp.add_hook('on_load', 60, function()
		mp.set_property('file-local-options/demuxer-max-bytes', '512KiB')
	end)
end

local function cache()
	return mp.get_property_native('demuxer-cache-state') or {}
end

local function low_level_seeks()
	return cache()['debug-low-level-seeks']
end

local function ranges()
	return #(cache()['seekable-ranges'] or {})
end

local function jump()
	return mp.get_property_native('user-data/percent-seek') or {}
end

-- Presses a number key and waits for the seek it causes to finish; the position after it.
local function press(key)
	local done = H.expect_event('playback-restart')
	mp.commandv('keypress', key)
	H.check('key ' .. key .. ' seeks', done(5))
	H.sleep(0.2)
	return mp.get_property_number('time-pos')
end

local function from_buffer(key, want)
	local before = low_level_seeks()
	local pos = press(key)
	H.eq('key ' .. key .. ' lands at ' .. want, pos, want, 1.5)
	H.eq('key ' .. key .. ': taken from the buffer', jump().buffered, true)
	return before
end

H.run(function()
	mp.set_property_native('pause', true)
	local duration = mp.get_property_number('duration') or 0

	if PHASE == 'hls' then
		H.check('lavf reads it as HLS', mp.get_property('file-format') == 'hls', mp.get_property('file-format'))
		H.expect('the whole playlist is buffered', function()
			return cache()['eof-cached'] == true and cache()['bof-cached'] == true and ranges() == 1
		end, true, nil, 10)
		for _, c in ipairs({ { '5', 0.5 }, { '9', 0.9 }, { '0', 0 } }) do
			local before = from_buffer(c[1], duration * c[2])
			H.eq('key ' .. c[1] .. ': no demuxer seek (nothing read again)', low_level_seeks(), before)
			H.eq('key ' .. c[1] .. ': still one buffered range', ranges(), 1)
		end
		return
	end

	-- ts
	H.check(
		'a 180 s MPEG-TS clip',
		mp.get_property('file-format') == 'mpegts' and duration > 170,
		tostring(mp.get_property('file-format')) .. ' ' .. duration
	)
	H.expect('the first seconds are buffered, not the rest', function()
		local r = (cache()['seekable-ranges'] or {})[1]
		return ranges() == 1 and r ~= nil and r['end'] >= 2 and not cache()['eof-cached']
	end, true, nil, 10)
	local before = low_level_seeks()
	local pos = press('5')
	H.eq("key 5 (not buffered): mpv's percent seek", jump().buffered, false)
	H.eq('... one demuxer seek', low_level_seeks(), before + 1)
	H.eq('... lands at 50 %', pos, duration * 0.5, 5)

	-- the rest of the file: the range from 50 % reads on to the end (a demuxer idle at
	-- its limit takes a new one when playback takes a packet, so it plays meanwhile)
	mp.set_property('file-local-options/demuxer-max-bytes', '150MiB')
	mp.set_property_native('pause', false)
	H.expect('the rest is buffered as a second range', function()
		return cache()['eof-cached'] == true and ranges() == 2
	end, true, nil, 10)
	mp.set_property_native('pause', true)
	before = from_buffer('7', duration * 0.7)
	H.eq('key 7: no demuxer seek (nothing read again)', low_level_seeks(), before)
	H.eq('key 7: still two ranges', ranges(), 2)
	-- the first range, kept beside the second (the demuxer then resumes reading at its end)
	from_buffer('0', 0)
end)
