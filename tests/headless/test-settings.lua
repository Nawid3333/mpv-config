-- Scripts/settings.lua (2026-10-09): the settings that differ from PC to PC.
-- Five processes (tests/run-tests.ps1, "settings"):
--   new      - a new install: mpv's defaults (subtitles follow Windows' language,
--              the file's default audio, HDR brightness auto), the buffer
--              recommended for this PC's memory; a choice in the menu applies
--              and is saved;
--   restored - a FRESH process restores the choices (AGENTS.md validation 6a);
--   legacy   - a PC that ran this config before (the runner removes
--              settings.json and leaves a speed.json after "restored") keeps what
--              mpv.conf gave everyone until then: de,en, 350 nits; its 1 GB is the
--              RAM budget, with FastStream's other buffer defaults; the start
--              waits Adaptive (mpv.conf's 3 s gave way to it everywhere);
--   migrated - a settings.json from before 2026-10-12 (Buffering = 2 GB, the
--              owner's, and the fixed 3 s wait): 2 GB becomes the RAM budget, the
--              3 s Adaptive, the old keys go;
--   damaged  - a settings.json that is no JSON (the runner writes one after
--              "migrated"): it is kept beside as settings.json.corrupt-<time>, and a
--              good one is written, not the defaults over it without a word (#96).
-- The buffering itself: test-stream-buffer.lua.
-- MPV_TEST_PHASE names the phase.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local PHASE = os.getenv('MPV_TEST_PHASE') or 'new'

local function prop(name)
	return function()
		return mp.get_property(name)
	end
end

local function peak()
	return mp.get_property('options/target-peak')
end

local function saved()
	local f = io.open(mp.command_native({ 'expand-path', '~~state/settings.json' }), 'r')
	if not f then
		return nil
	end
	local data = utils.parse_json(f:read('*a'))
	f:close()
	return data
end

local function published(key)
	return (mp.get_property_native('user-data/settings') or {})[key]
end

-- what stream-buffer.lua buffers the next video with
local function buffering(key)
	return function()
		return (mp.get_property_native('user-data/settings/buffering') or {})[key]
	end
end

local function set(key, value)
	mp.commandv('script-message-to', 'settings', 'set', key, value)
	H.sleep(0.15)
end

-- cache-pause-initial as each file's on_load left it, i.e. what that file's
-- start waits with: settings.lua's hook (priority 50) runs before this one
-- (lower runs first). Once the file has started it reads no (a seek plays at
-- once), so the start can only be seen here.
local initial_at_load = {}
mp.add_hook('on_load', 60, function()
	initial_at_load[#initial_at_load + 1] = mp.get_property('options/cache-pause-initial')
end)
local function last_initial()
	return initial_at_load[#initial_at_load]
end

local function initial()
	return mp.get_property('options/cache-pause-initial')
end

-- A seek on the playing file, and back once it has landed.
local function seek_to(seconds)
	local restarted = H.expect_event('playback-restart')
	mp.commandv('seek', tostring(seconds), 'absolute', 'exact')
	return restarted(5)
end

H.run(function()
	if PHASE == 'new' then
		H.eq('a new install: subtitle languages empty (subtitles follow Windows)', mp.get_property('slang'), '')
		H.eq("... audio languages empty (the file's default track)", mp.get_property('alang'), '')
		H.eq('... seeded from the defaults, not the old values', published('seeded'), 'defaults')
		local rec = published('ram_recommended')
		H.check(
			"... the PC's memory is read (LuaJIT FFI)",
			type(published('ram_gb')) == 'number',
			tostring(published('ram_gb'))
		)
		H.eq('... RAM for buffered video: Auto', published('ram_budget'), 'auto')
		H.eq('... which uses the budget recommended for this PC', buffering('ram_budget')(), rec)
		H.check(
			"... and FastStream's other buffer defaults",
			buffering('download_all')() == true
				and buffering('max_video_size')() == 5e9
				and buffering('buffer_to_disk')() == true
				and buffering('buffer_ahead')() == 300
				and buffering('buffer_behind')() == 20,
			utils.format_json(mp.get_property_native('user-data/settings/buffering'))
		)
		H.eq(
			"... a local file reads mpv's 150 MB ahead, within 3/4 of that budget",
			tonumber(mp.get_property('options/demuxer-max-bytes')),
			math.floor(math.max(math.min(150 * 1048576, rec * 0.75), 4 * 1048576))
		)
		H.eq('... starts Adaptive', published('start_wait'), 'auto')
		H.eq('... which waits before the start', initial_at_load[1], 'yes')
		-- what the line brings per second of the stream decides the wait (mpv ends a
		-- wait as soon as the buffer reaches cache-pause-wait)
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '5')
		H.expect(
			'... a line 5x the stream: 1 s of buffer, it starts at once',
			prop('options/cache-pause-wait'),
			'1.000000'
		)
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '0.6')
		H.expect('... a line slower than the stream: buffers longer', function()
			return (mp.get_property_number('options/cache-pause-wait') or 0) > 1.5
		end, true)
		mp.commandv('script-message-to', 'settings', 'adaptive-line', 'none')
		H.expect('... no speed known yet: 3 s, as before', prop('options/cache-pause-wait'), '3.000000')
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '')
		-- mpv applies cache-pause-initial after every seek too (playloop.c): a jump
		-- past the downloaded part waited for 3 s more of the stream
		H.expect('... but not after a seek: off once the file has started', initial, 'no')
		H.check('a seek lands', seek_to(1))
		H.eq('... and the initial wait stays off after it', initial(), 'no')
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '1.5')
		H.expect('... and a stall waits as the line says', prop('options/cache-pause-wait'), '1.000000')
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '')
		local s = saved()
		H.check(
			'... and settings.json written at once (decided once per PC)',
			s and s.hdr_peak == 'auto',
			utils.format_json(s)
		)
		H.eq('SDR file: target-peak auto', peak(), 'auto')
		H.load(H.media_path('hdr/pq.mkv'))
		H.eq('the next file buffers before its start again', last_initial(), 'yes')
		H.expect('... and plays its seeks at once', initial, 'no')
		H.expect('the HDR clip is PQ', prop('video-params/gamma'), 'pq')
		H.expect('HDR file at HDR brightness Auto: target-peak auto', peak, 'auto')

		set('hdr_peak', '350')
		H.expect('HDR brightness 350 applies to the HDR video at once', peak, '350')
		H.load(H.media_path('plain/clip.mkv'))
		H.expect('an SDR file after it: target-peak back to auto (SDR at full brightness)', peak, 'auto')
		H.load(H.media_path('hdr/pq.mkv'))
		H.expect('the next HDR file: 350 again', peak, '350')

		set('slang', 'de,en')
		H.expect('Subtitle language German, then English -> slang', prop('slang'), 'de,en')
		set('alang', 'ja,en')
		H.expect('Audio language Japanese, then English -> alang', prop('alang'), 'ja,en')
		set('ram_budget', '150000000')
		H.expect('RAM for buffered video 150 MB -> for the next video', buffering('ram_budget'), 150e6)
		set('download_all', 'no')
		H.expect('Predownload the whole video off', buffering('download_all'), false)
		set('buffer_to_disk', 'no')
		H.expect('Keep video on disk off', buffering('buffer_to_disk'), false)
		set('max_video_size', '-1')
		H.expect('Maximum size: no limit', buffering('max_video_size'), -1)
		set('buffer_ahead', '0')
		H.expect('Seconds ahead 0', buffering('buffer_ahead'), 0)
		set('buffer_behind', '600')
		H.expect('Seconds behind 600', buffering('buffer_behind'), 600)
		set('start_wait', '0')
		H.expect("Start at once -> mpv's own 1 s after a stall", prop('options/cache-pause-wait'), '1.000000')
		H.load(H.media_path('plain/clip.mkv'))
		H.eq('... and no wait before the next start', last_initial(), 'no')
		set('start_wait', '5')
		H.expect('Buffer 5 s -> cache-pause-wait 5', prop('options/cache-pause-wait'), '5.000000')
		H.eq('... the playing file has started: its seeks still play at once', initial(), 'no')
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '5')
		H.sleep(0.3)
		H.eq('... and the line decides nothing then', mp.get_property('options/cache-pause-wait'), '5.000000')
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '')
		set('download_all', 'yes')
		set('buffer_to_disk', 'yes')
		H.load(H.media_path('plain/clip.mkv'))
		H.eq('... and the next start buffers first', last_initial(), 'yes')
		H.eq('Predownload and disk on: never on disk for a local file', mp.get_property('cache-on-disk'), 'no')
		set('ram_budget', '1000000000')
		H.load(H.media_path('hdr/pq.mkv'))
		H.expect('back on the HDR clip: 350', peak, '350')
		set('hdr_peak', 'banana')
		set('ram_budget', 'huge')
		set('buffer_ahead', '-7')
		set('slang', 'de;rm -rf')
		H.sleep(0.5)
		H.eq('invalid values are ignored', mp.get_property('slang') .. ' ' .. peak(), 'de,en 350')
		H.expect('... and a banner says so', function()
			for _, c in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
				if c.id == 'settings' then
					return c.title
				end
			end
		end, 'Not changed')
		local s2 = saved()
		H.check(
			'... the choices are in settings.json',
			s2
				and s2.slang == 'de,en'
				and s2.alang == 'ja,en'
				and s2.hdr_peak == 350
				and s2.ram_budget == 1e9
				and s2.download_all == true
				and s2.buffer_to_disk == true
				and s2.max_video_size == -1
				and s2.buffer_ahead == 0
				and s2.buffer_behind == 600
				and s2.buffer == nil
				and s2.start_wait == 5
				and s2.buffer_wait == nil,
			utils.format_json(s2)
		)
		-- a choice made in the open menu keeps it open and shows at once (update-menu)
		mp.commandv('script-message-to', 'settings', 'open')
		H.expect('the Settings menu opens', function()
			return mp.get_property_native('user-data/uosc/menu/type')
		end, 'settings-menu', nil, 3)
		set('hdr_peak', '400')
		H.sleep(0.3)
		H.eq('... and stays open after a choice', mp.get_property_native('user-data/uosc/menu/type'), 'settings-menu')
		set('hdr_peak', '350')
		mp.commandv('script-message-to', 'uosc', 'close-menu')
	elseif PHASE == 'restored' then
		H.eq('a new process restores the subtitle languages', mp.get_property('slang'), 'de,en')
		H.eq('... and the audio languages', mp.get_property('alang'), 'ja,en')
		H.eq('... not seeded again', published('seeded'), nil)
		H.eq('... the RAM budget (1 GB)', buffering('ram_budget')(), 1e9)
		H.eq('... seconds behind (600)', buffering('buffer_behind')(), 600)
		H.eq('... and the wait (5 s)', mp.get_property('options/cache-pause-wait'), '5.000000')
		H.load(H.media_path('hdr/pq.mkv'))
		H.expect('... and the HDR brightness (350 for the HDR clip)', peak, '350')
	elseif PHASE == 'legacy' then
		H.eq('a PC that ran this config before keeps slang=de,en', mp.get_property('slang'), 'de,en')
		H.eq('... alang=de,en', mp.get_property('alang'), 'de,en')
		H.eq('... seeded from the old values', published('seeded'), 'legacy')
		H.eq('... its tuned 1 GB is the RAM budget now', buffering('ram_budget')(), 1e9)
		H.eq("... with FastStream's defaults: predownload on", buffering('download_all')(), true)
		H.eq('... beyond the RAM on disk', buffering('buffer_to_disk')(), true)
		H.eq('... and waits Adaptive at the start', published('start_wait'), 'auto')
		-- the timer measures while a file waits: the next file's load (3 s until it
		-- knows the line) and a line 5x the stream
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '5')
		set('start_wait', '10')
		set('start_wait', 'auto')
		-- H.expect: on a slow runner the second message can still be on its way after
		-- set()'s 0.15 s, and the value read was still the 10 s just chosen
		H.expect(
			'... chosen again while a file plays: 3 s until it measures',
			prop('options/cache-pause-wait'),
			'3.000000'
		)
		H.load(H.media_path('plain/clip.mkv'))
		H.expect("... the next file's wait follows the line (1 s)", prop('options/cache-pause-wait'), '1.000000')
		-- the caps: a stall waits at most 10 s, the first frame at most the old 3 s
		-- (the 20 s clip has more than 10 s left here)
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '0')
		H.expect(
			'... a stall on a line that brings nothing: 10 s at most',
			prop('options/cache-pause-wait'),
			'10.000000'
		)
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '0.3')
		H.load(H.media_path('plain/clip.mkv'))
		H.expect('... before the first frame on a slow line: 3 s at most', prop('options/cache-pause-wait'), '3.000000')
		mp.commandv('script-message-to', 'settings', 'adaptive-line', '')
		H.load(H.media_path('hdr/pq.mkv'))
		H.expect('... and 350 nits for HDR, as [hdr-target-peak] gave it', peak, '350')
		local s = saved()
		H.check('... written to settings.json, so it is decided once', s and s.slang == 'de,en', utils.format_json(s))
	elseif PHASE == 'migrated' then
		H.eq('Buffering 2 GB from before: the RAM budget now', buffering('ram_budget')(), 2e9)
		H.eq('... predownload on (the owner moved every PC)', buffering('download_all')(), true)
		H.eq('... the other settings kept', mp.get_property('slang'), 'de,en')
		H.eq('... the fixed 3 s wait from before (its default): Adaptive now', published('start_wait'), 'auto')
		local s = saved()
		H.check(
			'... written at once, without the old keys',
			s
				and s.ram_budget == 2e9
				and s.buffer == nil
				and s.hdr_peak == 350
				and s.start_wait == 'auto'
				and s.buffer_wait == nil,
			utils.format_json(s)
		)
	elseif PHASE == 'damaged' then
		local dir = mp.command_native({ 'expand-path', '~~state/' })
		local aside = {}
		for _, name in ipairs(utils.readdir(dir, 'files') or {}) do
			if name:match('^settings%.json%.corrupt%-') then
				aside[#aside + 1] = name
			end
		end
		H.eq('a damaged settings.json is kept beside it', #aside, 1)
		local f = #aside == 1 and io.open(utils.join_path(dir, aside[1]), 'r')
		local kept = f and f:read('*a')
		if f then
			f:close()
		end
		H.eq('... as it was', kept, '{"slang":"de,en", broken')
		H.check('... and a good settings.json is written', type(saved()) == 'table', utils.format_json(saved()))
		for _, name in ipairs(aside) do
			os.remove(utils.join_path(dir, name))
		end
	end
end)
