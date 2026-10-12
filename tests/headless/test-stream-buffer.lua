-- Scripts/stream-buffer.lua (2026-10-12): FastStream's buffer settings in mpv.
-- Two processes (tests/run-tests.ps1, "stream-buffer"):
--   stream - stream_buffer-local_is_stream=yes makes long/long.mkv (14.5 MB, 180 s)
--            buffer as a stream would (no test serves HTTP), and headroom_mb=0 puts
--            the RAM limit on the budget (a local file is read at once): predownload in RAM,
--            the switch to disk just before the RAM budget (and the demuxer reading
--            on after it - a demuxer idle at its limit reads new options only
--            when playback takes a packet), on disk from the start, the maximum
--            size, a window (seconds ahead/behind), RAM only, nothing kept;
--   local  - a local file: mpv's 150 MB / 50 MB within the RAM budget, never on disk.
-- The real stream was measured by hand: a 61-minute 2.9 GB HLS stream (the PR).
-- MPV_TEST_PHASE names the phase.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local PHASE = os.getenv('MPV_TEST_PHASE') or 'stream'
local MiB = 1048576
local LONG = H.media_path('long/long.mkv')

local function set(key, value)
	mp.commandv('script-message-to', 'settings', 'set', key, tostring(value))
	H.sleep(0.15)
end

local function buf(key)
	return function()
		return (mp.get_property_native('user-data/stream-buffer') or {})[key]
	end
end

local function cache(key)
	return function()
		return (mp.get_property_native('demuxer-cache-state') or {})[key]
	end
end

local function opt(name)
	return function()
		return mp.get_property('options/' .. name)
	end
end

local function num(get)
	return function()
		return tonumber(get())
	end
end

-- mpv prints the cache-secs option with 6 decimals
local function secs(n)
	return string.format('%.6f', n)
end

H.run(function()
	if PHASE == 'stream' then
		local cfg = mp.get_property_native('user-data/settings/buffering') or {}
		H.check(
			"settings.lua publishes FastStream's defaults for a new install",
			cfg.download_all == true
				and cfg.max_video_size == 5e9
				and cfg.buffer_to_disk == true
				and cfg.buffer_ahead == 300
				and cfg.buffer_behind == 20
				and type(cfg.ram_budget) == 'number'
				and cfg.ram_budget >= 150e6,
			utils.format_json(cfg)
		)

		-- 1. defaults: the whole video, in RAM (14.5 MB is far below any Auto budget)
		H.load(LONG)
		H.expect('defaults: a stream starts in RAM', buf('storage'), 'ram')
		H.eq('... predownloading', buf('mode')(), 'predownload')
		H.eq("... read ahead to the end (mpv's own no-limit cache-secs)", opt('cache-secs')(), secs(3600000))
		H.eq('... nothing on disk', opt('cache-on-disk')(), 'no')
		H.eq('... the RAM budget is the ahead limit', num(opt('demuxer-max-bytes'))(), math.floor(cfg.ram_budget))
		H.check('... and nothing trimmed behind', num(opt('demuxer-max-back-bytes'))() >= 1024 * 1024 * MiB)
		H.expect('... the whole video is read', cache('eof'), true, nil, 10)
		H.eq('... and it stayed in RAM', buf('storage')(), 'ram')

		-- 2. a RAM budget smaller than the video: RAM, then disk
		set('ram_budget', 4000000)
		H.load(LONG)
		H.expect('RAM 4 MB: on disk once the budget is (about to be) full', buf('storage'), 'disk', nil, 5)
		local at = buf('switched_at')()
		H.check('... switched at no more than the budget', at and at <= 4000000 + MiB, tostring(at))
		H.eq('... cache-on-disk on for this file', opt('cache-on-disk')(), 'yes')
		H.eq(
			'... and demuxer-max-bytes raised by the metadata room',
			num(opt('demuxer-max-bytes'))(),
			(at or 0) + 1024 * MiB
		)
		-- the demuxer sat idle at 4 MB: playback taking packets has to wake it
		H.check(
			'... the demuxer reads on, into the temp file',
			H.wait_until(function()
				return (cache('file-cache-bytes')() or 0) > 5 * MiB
			end, 10),
			tostring(cache('file-cache-bytes')())
		)
		H.expect('... to the end of the video', cache('eof'), true, nil, 10)
		H.check('... the RAM part stayed at the budget', (buf('ram_bytes')() or 0) <= 4000000 + MiB)

		-- 3. no RAM: on disk from the start
		set('ram_budget', 0)
		H.load(LONG)
		H.eq('RAM 0 with the disk on: on disk from the start', buf('storage')(), 'disk')
		H.eq('... switched at 0', buf('switched_at')(), 0)
		H.expect('... and read to the end', cache('eof'), true, nil, 10)

		-- 4. the maximum size: a predownload stops there, a window follows
		set('ram_budget', 4000000)
		set('max_video_size', 6000000)
		H.load(LONG)
		H.expect('max size 6 MB: the predownload stops there', buf('reason'), 'size', nil, 10)
		H.eq('... a window from then on', buf('mode')(), 'window')
		H.eq('... seconds ahead (300)', opt('cache-secs')(), secs(300))
		local back = num(opt('demuxer-max-back-bytes'))()
		-- 20 s at this clip's ~0.6 Mbit/s (or 1 MB/s before the bitrate is known)
		H.check('... seconds behind (20) as bytes', back and back > 100000 and back < 40 * MiB, tostring(back))

		-- 5. predownload off: a window at once
		set('download_all', 'no')
		set('buffer_ahead', 30)
		set('buffer_behind', 0)
		H.load(LONG)
		H.eq('predownload off: a window', buf('mode')(), 'window')
		H.eq('... because predownload is off', buf('reason')(), 'off')
		H.eq('... 30 s ahead', opt('cache-secs')(), secs(30))
		H.eq('... behind 0: played video dropped at once', opt('demuxer-max-back-bytes')(), '0')
		set('buffer_ahead', -1)
		H.load(LONG)
		H.eq('ahead no limit: the whole video, even with predownload off', opt('cache-secs')(), secs(3600000))
		-- 0 is 0, and only an empty field (-1) is no limit (the owner's rule, 2026-10-12)
		set('buffer_ahead', 0)
		H.load(LONG)
		H.eq('ahead 0: nothing ahead (cache-secs 0)', opt('cache-secs')(), secs(0))
		H.eq("... mpv's own 1 s read-ahead 0 too", opt('demuxer-readahead-secs')(), secs(0))
		local pos = mp.get_property_number('time-pos') or 0
		H.sleep(1.5)
		H.check(
			'... and the video still plays',
			(mp.get_property_number('time-pos') or 0) > pos + 0.5,
			tostring(mp.get_property_number('time-pos'))
		)
		set('download_all', 'yes')
		set('buffer_ahead', 300)
		set('max_video_size', 0)
		H.load(LONG)
		H.eq('max size 0: nothing predownloaded, a window at once', buf('mode')(), 'window')
		H.eq('... of the seconds ahead (300)', opt('cache-secs')(), secs(300))
		H.eq("... with mpv's own read-ahead as it is", opt('demuxer-readahead-secs')(), secs(1))
		set('max_video_size', -1)
		H.load(LONG)
		H.eq('max size no limit (an empty field): the whole video', buf('mode')(), 'predownload')
		H.check(
			'... stopped only by 60 % of the free disk space (more than 1 GB here)',
			buf('cap')() == -1 or buf('cap')() > 1e9,
			tostring(buf('cap')())
		)

		-- 6. RAM only
		set('download_all', 'yes')
		set('max_video_size', 5e9)
		set('buffer_behind', 20)
		set('buffer_ahead', 300)
		set('buffer_to_disk', 'no')
		H.load(LONG)
		H.sleep(2)
		H.eq('disk off, RAM 4 MB: never on disk', buf('storage')(), 'ram')
		H.eq('... cache-on-disk off', opt('cache-on-disk')(), 'no')
		H.check(
			'... ahead + behind within the budget',
			(cache('total-bytes')() or 0) <= 4000000 + 2 * MiB,
			tostring(cache('total-bytes')())
		)
		H.expect('... the predownload ends at the budget: a window', buf('reason'), 'size', nil, 5)

		-- 7. nothing kept
		set('ram_budget', 0)
		H.load(LONG)
		H.eq('RAM 0 and disk off: nothing kept', buf('storage')(), 'none')
		H.eq("... mpv's cache off", opt('cache')(), 'no')
		H.eq('... and nothing read ahead (its own 1 s read-ahead 0 too)', opt('demuxer-readahead-secs')(), secs(0))

		-- 8. no limit: all in RAM
		set('buffer_to_disk', 'yes')
		set('ram_budget', -1)
		H.load(LONG)
		H.eq('RAM no limit: all in RAM', buf('storage')(), 'ram')
		H.check('... no ahead limit', num(opt('demuxer-max-bytes'))() >= 1024 * 1024 * MiB)
		H.expect('... read to the end', cache('eof'), true, nil, 10)
		H.eq('... never on disk', buf('storage')(), 'ram')

		-- 9. a live stream: no end to predownload to (an endless lavfi source; mpv reports
		-- its cached end as the duration, which grows)
		set('ram_budget', 'auto')
		-- realtime: generated at 1x, as a live stream comes (unpaced it would be read as fast as made)
		H.load('av://lavfi:testsrc2=size=320x180:rate=24,realtime')
		H.eq('a source without an end: predownload at first', buf('mode')(), 'predownload')
		H.expect('... a window once its duration grew for 3 s (live)', buf('reason'), 'live', nil, 6)
		H.eq('... seconds ahead', opt('cache-secs')(), secs(300))

		-- 10. Custom...: the values a user types
		local function parsed(key, text)
			mp.commandv('script-message-to', 'settings', 'parse', key, text)
			H.sleep(0.1)
			return mp.get_property_native('user-data/settings-parsed')
		end
		H.eq("typed '3 GB' -> 3,000,000,000 bytes", parsed('ram_budget', '3 GB'), 3e9)
		H.eq("typed '800' -> 800 MB", parsed('ram_budget', '800'), 800e6)
		H.eq("typed '1,5gb' -> 1.5 GB", parsed('max_video_size', '1,5gb'), 1.5e9)
		H.eq('typed nothing -> no limit', parsed('max_video_size', ''), -1)
		H.eq("typed '0' -> none", parsed('ram_budget', '0'), 0)
		H.eq("typed '10 min' -> 600 s", parsed('buffer_ahead', '10 min'), 600)
		H.eq("typed '90' -> 90 s", parsed('buffer_behind', '90'), 90)
		H.eq("typed 'banana' -> not a value", parsed('ram_budget', 'banana'), 'invalid')
		set('ram_budget', 'banana')
		H.eq('... and an invalid value is not set', mp.get_property_native('user-data/settings').ram_budget, 'auto')

		-- the prompt itself (mp.input, mpv's console line), as a click on Custom... in the
		-- open Settings menu starts it, typed through mpv's own input (keypress). The menu
		-- makes way while the line is open: its own keys (type to search) took what was
		-- typed on CI (2026-10-12).
		mp.commandv('script-message-to', 'settings', 'open')
		H.expect('Custom...: the Settings menu is open', function()
			return mp.get_property_native('user-data/uosc/menu/type')
		end, 'settings-menu', nil, 3)
		mp.commandv('script-message-to', 'settings', 'custom', 'ram_budget')
		H.expect('... the input line opens', function()
			return mp.get_property_native('user-data/mpv/console/open')
		end, true, nil, 3)
		H.expect('... and the menu makes way for it', function()
			return mp.get_property_native('user-data/uosc/menu/type')
		end, nil, nil, 3)
		-- a typist's pace, after a moment for the line to take its keys
		H.sleep(0.5)
		for _, k in ipairs({ '2', '.', '5', 'SPACE', 'G', 'B', 'ENTER' }) do
			mp.commandv('keypress', k)
			H.sleep(0.05)
		end
		H.expect('... typed "2.5 GB" and Enter: the RAM budget is 2.5 GB', function()
			return (mp.get_property_native('user-data/settings') or {}).ram_budget
		end, 2.5e9, nil, 3)
		H.expect('... and the input line closed', function()
			return mp.get_property_native('user-data/mpv/console/open')
		end, false, nil, 3)
		H.expect('... and the Settings menu back', function()
			return mp.get_property_native('user-data/uosc/menu/type')
		end, 'settings-menu', nil, 3)
		mp.commandv('script-message-to', 'uosc', 'close-menu')
		set('ram_budget', 'auto')

		-- 11. the menu: one submenu per FastStream option
		mp.commandv('script-message-to', 'settings', 'open')
		H.expect('the Settings menu opens', function()
			return mp.get_property_native('user-data/uosc/menu/type')
		end, 'settings-menu', nil, 3)
		mp.commandv('script-message-to', 'uosc', 'close-menu')
	else
		H.eq('a local file: not buffered as a stream', buf('storage')(), 'local')
		H.eq("... mpv's 150 MB ahead", opt('demuxer-max-bytes')(), tostring(150 * MiB))
		H.eq('... 50 MB behind', opt('demuxer-max-back-bytes')(), tostring(50 * MiB))
		H.eq('... never a disk copy of itself', opt('cache-on-disk')(), 'no')
		set('ram_budget', 100e6)
		H.load(H.media_path('plain/clip.mkv'))
		H.eq('... and ahead + behind within the RAM budget: 3/4 ahead', opt('demuxer-max-bytes')(), tostring(75e6))
		H.eq('... 1/4 behind', opt('demuxer-max-back-bytes')(), tostring(25e6))
		set('ram_budget', 0)
		H.load(H.media_path('plain/clip.mkv'))
		H.eq('RAM 0: no cache for a local file either', opt('cache')(), 'no')
	end
end)
