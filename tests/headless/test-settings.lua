-- Scripts/settings.lua (2026-10-09): the settings that differ from PC to PC.
-- Three processes (tests/run-tests.ps1, "settings"):
--   new      - a new install: mpv's defaults (subtitles follow Windows' language,
--              the file's default audio, HDR brightness auto), the buffer
--              recommended for this PC's memory; a choice in the menu applies
--              and is saved;
--   restored - a FRESH process restores the choices (AGENTS.md validation 6a);
--   legacy   - a PC that ran this config before (the runner removes
--              settings.json and leaves a speed.json after "restored") keeps what
--              mpv.conf gave everyone until then: de,en, 350 nits, 1 GB, 3 s.
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

-- MiB as mp.get_property prints a byte size
local function mib(n)
	return tostring(n * 1048576)
end

local function set(key, value)
	mp.commandv('script-message-to', 'settings', 'set', key, value)
	H.sleep(0.15)
end

H.run(function()
	if PHASE == 'new' then
		H.eq('a new install: subtitle languages empty (subtitles follow Windows)', mp.get_property('slang'), '')
		H.eq("... audio languages empty (the file's default track)", mp.get_property('alang'), '')
		H.eq('... seeded from the defaults, not the old values', published('seeded'), 'defaults')
		local rec = published('buffer_recommended')
		H.check(
			"... the PC's memory is read (LuaJIT FFI)",
			type(published('ram_gb')) == 'number',
			tostring(published('ram_gb'))
		)
		H.eq('... buffering Auto uses the size recommended for it', published('buffer_used'), rec)
		local REC_MIB = { small = 150, medium = 512, large = 1024 }
		H.eq('... and sets it', mp.get_property('options/demuxer-max-bytes'), mib(REC_MIB[rec] or 0))
		H.eq('... buffers 3 s before starting (as tuned)', mp.get_property('options/cache-pause-initial'), 'yes')
		H.eq('... and after a stall', mp.get_property('options/cache-pause-wait'), '3.000000')
		local s = saved()
		H.check(
			'... and settings.json written at once (decided once per PC)',
			s and s.hdr_peak == 'auto',
			utils.format_json(s)
		)
		H.eq('SDR file: target-peak auto', peak(), 'auto')
		H.load(H.media_path('hdr/pq.mkv'))
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
		set('buffer', 'small')
		H.expect("Buffering 150 MB (mpv's default) -> demuxer-max-bytes", prop('options/demuxer-max-bytes'), mib(150))
		H.expect('... and 50 MB kept behind for seeking back', prop('options/demuxer-max-back-bytes'), mib(50))
		set('buffer', 'xlarge')
		H.expect('Buffering 2 GB -> demuxer-max-bytes', prop('options/demuxer-max-bytes'), mib(2048))
		set('buffer_wait', '0')
		H.expect('Start at once -> cache-pause-initial no', prop('options/cache-pause-initial'), 'no')
		H.expect("... and mpv's own 1 s after a stall", prop('options/cache-pause-wait'), '1.000000')
		set('buffer_wait', '5')
		H.expect('Buffer 5 s -> cache-pause-initial yes', prop('options/cache-pause-initial'), 'yes')
		H.expect('... cache-pause-wait 5', prop('options/cache-pause-wait'), '5.000000')
		set('buffer', 'whole')
		H.load(H.media_path('plain/clip.mkv'))
		H.eq(
			'The whole video on disk: never for a local file (it would copy itself)',
			mp.get_property('cache-on-disk'),
			'no'
		)
		set('buffer', 'large')
		H.load(H.media_path('hdr/pq.mkv'))
		H.expect('back on the HDR clip: 350', peak, '350')
		set('hdr_peak', 'banana')
		set('buffer', 'huge')
		set('slang', 'de;rm -rf')
		H.sleep(0.5)
		H.eq('invalid values are ignored', mp.get_property('slang') .. ' ' .. peak(), 'de,en 350')
		local s2 = saved()
		H.check(
			'... the choices are in settings.json',
			s2
				and s2.slang == 'de,en'
				and s2.alang == 'ja,en'
				and s2.hdr_peak == 350
				and s2.buffer == 'large'
				and s2.buffer_wait == 5,
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
		H.eq('... the buffer (1 GB)', mp.get_property('options/demuxer-max-bytes'), mib(1024))
		H.eq('... and the wait (5 s)', mp.get_property('options/cache-pause-wait'), '5.000000')
		H.load(H.media_path('hdr/pq.mkv'))
		H.expect('... and the HDR brightness (350 for the HDR clip)', peak, '350')
	else
		H.eq('a PC that ran this config before keeps slang=de,en', mp.get_property('slang'), 'de,en')
		H.eq('... alang=de,en', mp.get_property('alang'), 'de,en')
		H.eq('... seeded from the old values', published('seeded'), 'legacy')
		H.eq('... 1 GB ahead, as tuned', mp.get_property('options/demuxer-max-bytes'), mib(1024))
		H.eq('... 128 MB behind', mp.get_property('options/demuxer-max-back-bytes'), mib(128))
		H.eq('... buffering 3 s first', mp.get_property('options/cache-pause-wait'), '3.000000')
		H.load(H.media_path('hdr/pq.mkv'))
		H.expect('... and 350 nits for HDR, as [hdr-target-peak] gave it', peak, '350')
		local s = saved()
		H.check('... written to settings.json, so it is decided once', s and s.slang == 'de,en', utils.format_json(s))
	end
end)
