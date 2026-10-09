-- settings.lua - the Settings menu, the Welcome menu (F1), and the settings that
-- differ from PC to PC (2026-10-09, for the one-click install: this config was
-- tuned on one PC - an RX 9070 XT, a 1440p IPS monitor, 63 GB RAM, German as the
-- first language - and those values shipped in mpv.conf as everyone's defaults).
--
-- Every choice is shown with what it does now, what was detected or measured,
-- and the recommended one marked; every option stays selectable (the user's
-- rule: "measure but still show the user what will be selected and then give
-- him the option to choose other too"). The menus stay open and show a choice
-- at once.
--
--   Settings (right-click menu > Settings, `script-message-to settings open`)
--   Welcome  (F1, Help, and the first start - Scripts/welcome.lua; `open-welcome`):
--            the same settings on top ("decide in the onboarding", the user,
--            2026-10-09), then every feature with its key.
--
--   Buffering - how far ahead a stream is read: 150 MB (mpv's default), 512 MB,
--     1 GB (the tuned value), 2 GB, or the whole video on disk (streams only, in
--     the temp folder, deleted when it closes - cache-on-disk). Auto takes the
--     size recommended for this PC's memory. Start and stalls: start at once, or
--     buffer N seconds first and after a stall (cache-pause-initial/-wait). A
--     seek never waits for it (2026-10-09, see apply_buffer()).
--   Upscaling quality, screen, Movie sharpness - gpu-toggles.lua owns them (and
--     ~~state/upscale.json); its items come from user-data/gpu-toggles/quality.
--   HDR brightness - target-peak while an HDR (PQ/HLG) video plays: the screen's
--     peak in nits, which the tone mapping aims at. Auto = mpv's own default
--     (203 nits on an SDR desktop; with Windows HDR on, what the display
--     reports). SDR video always gets auto: a peak set for every file made SDR
--     ~78 % as bright on the SDR desktop (2026-10-02; this replaced mpv.conf's
--     [hdr-target-peak] profile).
--   Subtitle / audio language - mpv's slang / alang. Empty = mpv's own choice:
--     subtitles in Windows' display language when the audio is another one
--     (subs-match-os-language), the file's default audio track.
--
--   The screen (2026-10-09, the user: "when I switch my monitor - 4K, another
--     refresh rate, other HDR - mpv should detect it via Windows, or let me
--     switch the targets manually"): the screen is what Windows reports for the
--     window's monitor (display-width x display-height @ display-fps). Every
--     screen seen is remembered with its own HDR brightness; a new one starts at
--     Auto (a peak tuned for one panel is wrong for the next) and a banner names
--     it, with F1 to check its settings. The upscaling follows the screen by itself
--     (gpu-toggles reads it per action; the shader warm-up warms again for a new size).
--
-- Every setting explains itself in its submenu (a dimmed note on what it does,
-- a pro or con next to each option); a gear button in the control bar opens the
-- Settings, right-click the Welcome menu.
--
-- Stored per PC in ~~state/settings.json (gitignored). A PC that ran this
-- config before (any state file of it is there) keeps exactly what mpv.conf
-- gave it until then - German, then English, 350 nits, 1 GB, 3 s - so an update
-- changes nothing there; a new install starts from the recommended values.
local mp = require('mp')
local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')

local opts = {
	-- no = only apply what settings.json says, never write it (the shader warm-up
	-- loads this script for the HDR brightness its clips are drawn with)
	write = true,
}
options.read_options(opts, 'settings')

local STATE_DIR = mp.command_native({ 'expand-path', '~~state/' })
local FILE = utils.join_path(STATE_DIR, 'settings.json')

-- What mpv.conf set for everyone until 2026-10-09.
local LEGACY = { slang = 'de,en', alang = 'de,en', hdr_peak = 350, buffer = 'large', buffer_wait = 3 }
local DEFAULTS = { slang = '', alang = '', hdr_peak = 'auto', buffer = 'auto', buffer_wait = 3 }
-- Files only a PC that already ran this config has (remember-speed.lua,
-- gpu-toggles.lua, stream-resume.lua, mpv's watch-later, the shader warm-up).
local LEGACY_MARKERS = {
	'~~state/speed.json',
	'~~state/movie-sharpness.json',
	'~~state/stream-resume.json',
	'~~state/watch_later',
	'~~cache/shader-warmup.stamp',
}

local HDR_LEVELS = { 300, 350, 400, 450, 600, 800, 1000 }
local LANGUAGES = {
	{ 'en', 'English' },
	{ 'de,en', 'German, then English' },
	{ 'fr,en', 'French, then English' },
	{ 'es,en', 'Spanish, then English' },
	{ 'it,en', 'Italian, then English' },
	{ 'pt,en', 'Portuguese, then English' },
	{ 'nl,en', 'Dutch, then English' },
	{ 'pl,en', 'Polish, then English' },
	{ 'tr,en', 'Turkish, then English' },
	{ 'ru,en', 'Russian, then English' },
	{ 'ar,en', 'Arabic, then English' },
	{ 'hi,en', 'Hindi, then English' },
	{ 'ja,en', 'Japanese, then English' },
	{ 'ko,en', 'Korean, then English' },
	{ 'zh,en', 'Chinese, then English' },
}
-- ahead/back in MiB (demuxer-max-bytes / demuxer-max-back-bytes)
local BUFFERS = {
	{ id = 'small', title = '150 MB', note = "mpv's default · least memory", ahead = 150, back = 50 },
	{ id = 'medium', title = '512 MB', note = 'for 8 GB of memory', ahead = 512, back = 64 },
	{ id = 'large', title = '1 GB', note = 'as tuned', ahead = 1024, back = 128 },
	{ id = 'xlarge', title = '2 GB', note = 'fewest stalls · most memory', ahead = 2048, back = 256 },
	{
		id = 'whole',
		title = 'The whole video (streams, on disk)',
		note = 'no stalls once loaded · uses disk space',
		ahead = 1024,
		back = 128,
		disk = true,
	},
}
local WAITS = { 0, 3, 5, 10 }

local function exists(path)
	return utils.file_info(mp.command_native({ 'expand-path', path })) ~= nil
end

local function read_file()
	local f = io.open(FILE, 'r')
	if not f then
		return nil
	end
	local data = utils.parse_json(f:read('*a'))
	f:close()
	return type(data) == 'table' and data or nil
end

local function valid_peak(v)
	if v == 'auto' then
		return v
	end
	v = tonumber(v)
	return v and v >= 80 and v <= 10000 and math.floor(v) or nil
end

local function valid_lang(v)
	return type(v) == 'string' and v:match('^[%w,%-]*$') and v or nil
end

local function buffer_by_id(id)
	for _, b in ipairs(BUFFERS) do
		if b.id == id then
			return b
		end
	end
	return nil
end

local function valid_buffer(v)
	return (v == 'auto' or buffer_by_id(v)) and v or nil
end

local function valid_wait(v)
	v = tonumber(v)
	return v and v >= 0 and v <= 60 and math.floor(v) or nil
end

-- This PC's memory in GB (LuaJIT's FFI, as title-bar.lua uses it; Windows only),
-- or nil.
local function read_ram_gb()
	local ok, ffi = pcall(require, 'ffi')
	if not ok then
		return nil
	end
	local ok2, gb = pcall(function()
		ffi.cdef([[
			typedef struct {
				uint32_t dwLength; uint32_t dwMemoryLoad;
				uint64_t ullTotalPhys; uint64_t ullAvailPhys;
				uint64_t ullTotalPageFile; uint64_t ullAvailPageFile;
				uint64_t ullTotalVirtual; uint64_t ullAvailVirtual; uint64_t ullAvailExtendedVirtual;
			} settings_memory_status;
			int GlobalMemoryStatusEx(settings_memory_status *buffer);
		]])
		local st = ffi.new('settings_memory_status')
		st.dwLength = ffi.sizeof(st)
		if ffi.C.GlobalMemoryStatusEx(st) == 0 then
			return nil
		end
		return tonumber(st.ullTotalPhys) / 1073741824
	end)
	return ok2 and gb or nil
end
local RAM_GB = read_ram_gb()

-- The buffer recommended for this PC: the stream waits in RAM (compressed), so
-- the size follows the memory; the tuned 1 GB from 12 GB on.
local function recommended_buffer()
	if not RAM_GB then
		return 'medium'
	elseif RAM_GB < 6 then
		return 'small'
	elseif RAM_GB < 12 then
		return 'medium'
	end
	return 'large'
end

local settings = {}
local from_file = read_file()
local seeded = nil -- 'legacy' | 'defaults' when this start created the file
do
	local base = DEFAULTS
	if not from_file then
		for _, path in ipairs(LEGACY_MARKERS) do
			if exists(path) then
				base = LEGACY
				break
			end
		end
		seeded = base == LEGACY and 'legacy' or 'defaults'
	end
	local src = from_file or {}
	settings.slang = valid_lang(src.slang) or base.slang
	settings.alang = valid_lang(src.alang) or base.alang
	settings.hdr_peak = valid_peak(src.hdr_peak) or base.hdr_peak
	settings.buffer = valid_buffer(src.buffer) or base.buffer
	settings.buffer_wait = valid_wait(src.buffer_wait) or base.buffer_wait
	-- every screen seen: key 'WxH@Hz' -> { label, seen, hdr_peak }
	settings.screens = {}
	if type(src.screens) == 'table' then
		for key, sc in pairs(src.screens) do
			if type(key) == 'string' and key:match('^%d+x%d+@%d+$') and type(sc) == 'table' then
				settings.screens[key] = {
					label = type(sc.label) == 'string' and sc.label or key,
					seen = type(sc.seen) == 'string' and sc.seen or nil,
					hdr_peak = valid_peak(sc.hdr_peak) or 'auto',
				}
			end
		end
	end
end

-- Through a temp file of this process's own, as the other state files.
local function save()
	if not opts.write then
		return
	end
	local json = utils.format_json(settings)
	local tmp = FILE .. '.' .. utils.getpid() .. '.tmp'
	local f = json and io.open(tmp, 'w')
	if not f then
		msg.warn('cannot write ' .. tmp)
		return
	end
	f:write(json)
	f:close()
	os.remove(FILE)
	if not os.rename(tmp, FILE) then
		msg.warn('cannot replace ' .. FILE)
	end
end

-- The decision is made once per PC: the next start must not take the legacy
-- values just because this session wrote speed.json.
if seeded then
	msg.verbose('settings.json: new, from the ' .. seeded .. ' values')
	save()
end

-- (both ids are validated; the fallback only satisfies the type checker)
local function effective_buffer()
	return buffer_by_id(settings.buffer == 'auto' and recommended_buffer() or settings.buffer) or BUFFERS[3]
end

-- ---- applying ----------------------------------------------------------------------
-- Before the first file: mpv waits for every script's main chunk before it
-- opens one, so the first file already uses these.
local function apply_languages()
	mp.set_property('slang', settings.slang)
	mp.set_property('alang', settings.alang)
end

-- A seek starts at once (2026-10-09, the user: "when I skip to a certain part of
-- a video, then the video doesn't play immediately"). cache-pause-initial holds
-- playback after EVERY seek, not only at a file's start: mpv clears
-- restart_complete on each seek (player/playloop.c, reset_playback_state()), and
-- handle_update_cache() then waits for cache-pause-wait seconds of buffer
-- whenever fewer are read - on a stream, each jump past what is downloaded
-- waited until 3 s more had arrived. So the initial wait is on until this
-- file's first start (playback-restart) and off from then on. A stall still
-- waits cache-pause-wait seconds: that path needs no cache-pause-initial.
local started = false -- this file has started: its next restarts are seeks
local function apply_initial_wait()
	mp.set_property('cache-pause-initial', (settings.buffer_wait > 0 and not started) and 'yes' or 'no')
end

-- For the next file (a running demuxer keeps its limits); the wait applies at once.
local function apply_buffer()
	local b = effective_buffer()
	mp.set_property('demuxer-max-bytes', b.ahead .. 'MiB')
	mp.set_property('demuxer-max-back-bytes', b.back .. 'MiB')
	local wait = settings.buffer_wait
	apply_initial_wait()
	mp.set_property('cache-pause-wait', tostring(wait > 0 and wait or 1))
end

-- The whole video on disk, for streams only: with cache-on-disk the packets go to
-- a temp file and the byte limits count only their metadata (~50 MB per hour,
-- the manual), so the read-ahead runs to the end (cache-secs). A local file read
-- ahead into a temp copy of itself would only fill the disk.
local NETWORK =
	{ http = true, https = true, ytdl = true, edl = true, rtmp = true, rtmps = true, rtsp = true, ftp = true }
local function is_stream(path)
	local scheme = type(path) == 'string' and path:match('^(%a[%w+.-]*)://')
	return scheme ~= nil and NETWORK[scheme:lower()] == true
end

mp.add_hook('on_load', 50, function()
	started = false
	apply_initial_wait() -- the wait before this file's start
	if effective_buffer().disk and is_stream(mp.get_property('path')) then
		mp.set_property('file-local-options/cache-on-disk', 'yes')
		mp.set_property('file-local-options/demuxer-cache-dir', os.getenv('TEMP') or '')
	end
end)

-- The first restart of a file is its start; every later one is a seek.
mp.register_event('playback-restart', function()
	if not started then
		started = true
		apply_initial_wait()
	end
end)

local function is_hdr()
	local gamma = mp.get_property('video-params/gamma', '')
	return gamma == 'pq' or gamma == 'hlg'
end

-- ---- the screen --------------------------------------------------------------------------
local current_screen = nil -- { key = '2560x1440@144', label = '2560x1440 @ 144 Hz' } once known

local function screen_from(w, h, fps)
	if not (w and h and w > 0 and h > 0) then
		return nil
	end
	local hz = fps and fps > 0 and math.floor(fps + 0.5) or nil
	return {
		key = string.format('%dx%d@%d', w, h, hz or 0),
		label = string.format('%dx%d', w, h) .. (hz and string.format(' @ %d Hz', hz) or ''),
	}
end

-- The HDR brightness for the screen the window is on (before one is known: the
-- value from before the screens were remembered).
local function screen_hdr_peak()
	local sc = current_screen and settings.screens[current_screen.key]
	if sc and sc.hdr_peak then
		return sc.hdr_peak
	end
	return settings.hdr_peak
end

local function apply_peak()
	local want = 'auto'
	local peak = screen_hdr_peak()
	if is_hdr() and peak ~= 'auto' then
		want = tostring(peak)
	end
	if mp.get_property('options/target-peak') ~= want then
		mp.set_property('target-peak', want)
	end
end

apply_languages()
apply_buffer()
mp.observe_property('video-params/gamma', 'string', apply_peak)

local function screen_count()
	local n = 0
	for _ in pairs(settings.screens) do
		n = n + 1
	end
	return n
end

local function publish()
	mp.set_property_native('user-data/settings', {
		slang = settings.slang,
		alang = settings.alang,
		hdr_peak = screen_hdr_peak(),
		screen = current_screen and current_screen.label or nil,
		screens = screen_count(),
		buffer = settings.buffer,
		buffer_used = effective_buffer().id,
		buffer_recommended = recommended_buffer(),
		buffer_wait = settings.buffer_wait,
		ram_gb = RAM_GB and math.floor(RAM_GB + 0.5) or nil,
		seeded = seeded,
	})
end
publish()

-- ---- the menus ----------------------------------------------------------------------------
local gpu = nil -- user-data/gpu-toggles/quality
local open_type = nil -- 'settings' | 'welcome' while one of them is open
local pending = nil -- the menu to open once gpu-toggles answered

local function notify(title, detail, seconds)
	mp.commandv('script-message-to', 'notify', 'show', 'settings', title, detail or '', tostring(seconds or 2))
end

local function peak_label(v)
	return v == 'auto' and 'Auto' or (tostring(v) .. ' nits')
end

local function lang_label(v)
	if v == '' then
		return 'Automatic'
	end
	for _, l in ipairs(LANGUAGES) do
		if l[1] == v then
			return l[2]
		end
	end
	return v
end

local function buffer_label()
	local b = effective_buffer()
	local title = b.disk and 'Whole video' or b.title
	return settings.buffer == 'auto' and ('Auto (' .. title .. ')') or title
end

local function wait_label(w)
	return w > 0 and string.format('buffer %d s', w) or 'start at once'
end

local function choice(title, hint, key, value, active, separator)
	return {
		title = title,
		hint = hint,
		value = { 'script-message-to', 'settings', 'set', key, tostring(value) },
		active = active,
		keep_open = true,
		separator = separator,
	}
end

-- A dimmed line that explains, at the top of a submenu (not selectable).
local function note(title, separator)
	return { title = title, muted = true, selectable = false, separator = separator }
end

local function buffer_items()
	local rec = buffer_by_id(recommended_buffer()) or BUFFERS[2]
	local ram = RAM_GB and string.format('%.0f GB RAM', RAM_GB) or 'memory unknown'
	local items = {
		note('How much of a stream is downloaded ahead of you.'),
		note('More: fewer stalls on a slow line, more memory.', true),
		choice(
			'Auto (recommended for this PC)',
			ram .. ' -> ' .. rec.title,
			'buffer',
			'auto',
			settings.buffer == 'auto',
			true
		),
	}
	for _, b in ipairs(BUFFERS) do
		local hint = b.note
		if b.id == rec.id then
			hint = (hint and (hint .. ' · ') or '') .. 'recommended'
		end
		items[#items + 1] = choice(b.title, hint, 'buffer', b.id, settings.buffer == b.id)
	end
	items[#items].separator = true
	items[#items + 1] = note('1 GB is about 11 minutes of a 1080p stream.')
	items[#items + 1] = note('Applies from the next video on.')
	return items
end

local WAIT_HINTS = {
	[0] = "mpv's default · fastest start, may stall early",
	[3] = 'as tuned · recommended',
	[5] = 'smoother on a slow line',
	[10] = 'longest wait, fewest stalls',
}

local function wait_items()
	local items = {
		note('Wait for some seconds of video before playing,'),
		note('and again when the stream ran dry (a stall).'),
		note('A seek plays at once, without this wait.', true),
	}
	for _, w in ipairs(WAITS) do
		local title = w > 0 and string.format('Buffer %d s first, and after a stall', w) or 'Start at once'
		items[#items + 1] = choice(title, WAIT_HINTS[w], 'buffer_wait', w, settings.buffer_wait == w)
	end
	return items
end

local function lang_items(key, auto_hint)
	local items = {
		note(
			key == 'slang' and 'The subtitle track picked when a video starts:'
				or 'The audio track picked when a video starts:'
		),
		note('the first of these languages the file has.', true),
		choice('Automatic', auto_hint, key, '', settings[key] == '', true),
	}
	local listed = settings[key] == ''
	for _, l in ipairs(LANGUAGES) do
		listed = listed or l[1] == settings[key]
		items[#items + 1] = choice(l[2], l[1], key, l[1], settings[key] == l[1])
	end
	if not listed then
		items[#items + 1] = { title = settings[key], hint = 'set by hand', active = true, keep_open = true }
	end
	return items
end

local function hdr_items()
	local peak = screen_hdr_peak()
	local items = {
		note("For HDR videos only: your screen's peak brightness"),
		note('(its spec sheet). Too high: bright parts clip.'),
		note('Too low: HDR looks dimmer than it could.'),
		note(
			current_screen and ('Set for this screen: ' .. current_screen.label)
				or 'This screen is read when a video plays.',
			true
		),
		choice("Auto (the screen's own value)", '203 nits on an SDR screen', 'hdr_peak', 'auto', peak == 'auto', true),
	}
	for _, nits in ipairs(HDR_LEVELS) do
		items[#items + 1] = choice(nits .. ' nits', nil, 'hdr_peak', nits, peak == nits)
	end
	return items
end

-- The settings, as submenus; `prefix` keeps the ids of the two menus apart.
local function settings_items(prefix)
	local items = {}
	local function sub(id, title, hint, list, separator)
		items[#items + 1] = { id = prefix .. id, title = title, hint = hint, items = list, separator = separator }
	end
	items[#items + 1] = note(
		current_screen and ('This screen: ' .. current_screen.label .. ' (read from Windows)')
			or 'The screen is read from Windows when a video plays.',
		true
	)
	sub('buffer', 'Buffering', buffer_label(), buffer_items())
	sub('wait', 'Start and stalls', wait_label(settings.buffer_wait), wait_items(), true)
	if gpu and type(gpu.quality_items) == 'table' then
		sub('quality', 'Upscaling quality', gpu.label, gpu.quality_items)
		sub('screen', 'Screen for upscaling', gpu.screen_label, gpu.screen_items)
		sub('sharpness', 'Movie sharpness', gpu.sharpness_label, gpu.sharpness_items, true)
	end
	sub('slang', 'Subtitle language', lang_label(settings.slang), lang_items('slang', "Windows' language"))
	sub('alang', 'Audio language', lang_label(settings.alang), lang_items('alang', "the file's default"))
	sub('hdr', 'HDR brightness', peak_label(screen_hdr_peak()), hdr_items())
	return items
end

-- ---- the feature tour (the Welcome menu's second half) ---------------------------------
-- Every key here is the one input.conf binds (tests/run-tests.ps1 checks them).
local function info(title, hint)
	return { title = title, hint = hint, muted = true, selectable = false }
end

local function run(title, hint, command)
	return { title = title, hint = hint, value = command }
end

local function tour_items()
	return {
		{
			title = 'Upscaling',
			hint = 'Shift+A, Shift+Y',
			items = {
				run('Anime upscaling on / off', 'Shift+A', 'script-binding gpu_toggles/toggle-anime'),
				run('Movie upscaling on / off', 'Shift+Y', 'script-binding gpu_toggles/toggle-movie'),
				info('Anime: Anime4K - clean lines, less noise', 'anime'),
				info('Movie: FSRCNNX / SSimSuperRes, picked by the scale', 'films'),
				info('Local files start without; FastStream streams pick one', 'Auto'),
				info('The upscale button: click = next, right-click = menu', 'toolbar'),
			},
		},
		{
			title = 'Speed',
			hint = 'r g b q w a y e h',
			items = {
				run('1x', 'r', 'script-binding speed_presets/preset 1'),
				run('2x', 'g', 'script-binding speed_presets/preset 2'),
				run('3x', 'q', 'script-binding speed_presets/preset 3'),
				info('2.5x b · 3.5x w · 4x a · 5x y · 8x e · 16x h', 'more'),
				info('The same key again goes back to the speed before', 'toggle'),
				info('-0.1 / +0.1', 's / d'),
				info('The last speed is kept for the next start', 'remembered'),
			},
		},
		{
			title = 'Subtitles and audio',
			hint = 'c, t',
			items = {
				run('Subtitles on / off', 'c', 'script-binding subtitle_toggle/smart-toggle'),
				run('Sync timeline: drag subtitles or audio into place', 't', 'script-binding subtitle_sync/toggle'),
			},
		},
		{
			title = 'Moving around',
			hint = 'arrows, j k, z x',
			items = {
				info('Back / forward 5 s', '← →'),
				info('Back / forward 10 s', 'j / k'),
				info('Back / forward 60 s', 'z / x'),
				info('Jump to 0 % ... 90 %', '0 - 9'),
				info('Volume ±10 / ±2', '↑ ↓ / wheel'),
				info('Mute', 'm'),
			},
		},
		{
			title = 'Streams from Firefox (FastStream)',
			hint = 'browser',
			items = {
				info('Allowlisted sites open in this window by themselves', 'MPV mode'),
				info('A stream continues where you stopped (7 days)', 'Home = start'),
				info('The next episode replaces this one and plays', 'one window'),
				run(
					'Stream, original page and file links, to copy',
					'source button',
					'script-message-to source_info open-menu'
				),
			},
		},
		{
			title = 'Window and information',
			hint = 'i, Q',
			items = {
				info('Play / pause, fullscreen, menu', 'click / double / right'),
				run('File and stream information', 'i', 'script-binding stats/display-page-1'),
				info('Quit and keep the position', 'Q'),
				info('Every key and menu entry', 'Tools > Key bindings'),
			},
		},
	}
end

local function header(title)
	return { title = title, muted = true, bold = true, selectable = false }
end

local function build_menu(kind)
	if kind == 'welcome' then
		local items = { header('Your settings - the recommended ones are marked') }
		for _, item in ipairs(settings_items('welcome-')) do
			items[#items + 1] = item
		end
		items[#items].separator = true
		items[#items + 1] = header('What this player can do')
		for _, item in ipairs(tour_items()) do
			items[#items + 1] = item
		end
		return {
			type = 'welcome-tour',
			title = 'Welcome to mpv',
			items = items,
			on_close = { 'script-message-to', 'settings', 'menu-closed', 'welcome' },
		}
	end
	local items = settings_items('settings-')
	items[#items].separator = true
	items[#items + 1] = {
		title = 'Welcome and feature tour',
		hint = 'F1',
		value = { 'script-message-to', 'settings', 'open-welcome' },
	}
	return {
		type = 'settings-menu',
		title = 'Settings',
		items = items,
		on_close = { 'script-message-to', 'settings', 'menu-closed', 'settings' },
	}
end

-- update = true: refresh the open menu (uosc ignores it once the menu is closed)
local function send_menu(kind, update)
	local json, err = utils.format_json(build_menu(kind))
	if not json then
		msg.error('settings menu: ' .. tostring(err))
	elseif update then
		mp.commandv('script-message-to', 'uosc', 'update-menu', json)
	else
		mp.commandv('script-message-to', 'uosc', 'open-menu', json)
	end
end

local function show(kind)
	pending = nil
	open_type = kind
	send_menu(kind, false)
end

local function open_menu(kind)
	-- the fresh upscaling state first (gpu-toggles answers in a few ms); open
	-- with what is there if it does not come
	pending = kind
	mp.commandv('script-message-to', 'gpu_toggles', 'publish-quality')
	mp.add_timeout(0.3, function()
		if pending == kind then
			show(kind)
		end
	end)
end

mp.observe_property('user-data/gpu-toggles/quality', 'native', function(_, value)
	gpu = type(value) == 'table' and value or nil
	if pending then
		show(pending)
	elseif open_type then
		send_menu(open_type, true)
	end
end)

local SETTERS = {
	slang = function(v)
		v = valid_lang(v)
		if not v then
			return nil
		end
		settings.slang = v
		apply_languages()
		return 'Subtitle language: ' .. lang_label(v), 'from the next video on'
	end,
	alang = function(v)
		v = valid_lang(v)
		if not v then
			return nil
		end
		settings.alang = v
		apply_languages()
		return 'Audio language: ' .. lang_label(v), 'from the next video on'
	end,
	hdr_peak = function(v)
		v = valid_peak(v)
		if not v then
			return nil
		end
		local sc = current_screen and settings.screens[current_screen.key]
		if sc then
			sc.hdr_peak = v
		else
			settings.hdr_peak = v
		end
		apply_peak()
		local where = current_screen and ('for ' .. current_screen.label) or 'for HDR videos'
		return 'HDR brightness: ' .. peak_label(v), is_hdr() and (where .. ' · applied to this video') or where
	end,
	buffer = function(v)
		v = valid_buffer(v)
		if not v then
			return nil
		end
		settings.buffer = v
		apply_buffer()
		return 'Buffering: ' .. buffer_label(), 'from the next video on'
	end,
	buffer_wait = function(v)
		v = valid_wait(v)
		if not v then
			return nil
		end
		settings.buffer_wait = v
		apply_buffer()
		return 'Start and stalls: ' .. wait_label(v), nil
	end,
}

-- script-message-to settings set <key> <value>
mp.register_script_message('set', function(key, value)
	local setter = SETTERS[key]
	local title, detail
	if setter then
		title, detail = setter(value)
	end
	if not title then
		msg.warn('set: invalid ' .. tostring(key) .. ' = ' .. tostring(value))
		return
	end
	save()
	publish()
	notify(title, detail)
	if open_type then
		send_menu(open_type, true)
	end
end)

mp.register_script_message('open', function()
	open_menu('settings')
end)
mp.register_script_message('open-welcome', function()
	open_menu('welcome')
end)
mp.register_script_message('menu-closed', function(kind)
	if open_type == kind then
		open_type = nil
	end
end)

-- ---- the screen, as Windows reports it ------------------------------------------------------
-- A screen seen for the first time is remembered; the very first one takes the HDR
-- brightness from before (a PC from before keeps its 350 nits), any later one starts
-- at Auto and is announced.
local screen_retry = nil
local function screen_seen(w, h, fps, tries)
	local sc = screen_from(w, h, fps)
	if not sc or (current_screen and current_screen.key == sc.key) then
		return
	end
	-- The refresh rate can come a moment after the size (review, 2026-10-09):
	-- "2560x1440@0" would be remembered as a screen of its own, and the real
	-- "2560x1440@144" announced as new with its HDR brightness back at Auto.
	local size = sc.key:match('^(%d+x%d+)@')
	if sc.key:match('@0$') then
		for key, known in pairs(settings.screens) do
			if key:match('^(%d+x%d+)@') == size then
				sc = { key = key, label = known.label } -- the screen of that size seen before
				break
			end
		end
		if sc.key:match('@0$') and (tries or 0) < 5 then
			-- wait for the refresh rate; a screen that never reports one is kept without it
			if screen_retry then
				screen_retry:kill()
			end
			screen_retry = mp.add_timeout(0.5, function()
				screen_retry = nil
				screen_seen(
					mp.get_property_number('display-width'),
					mp.get_property_number('display-height'),
					mp.get_property_number('display-fps'),
					(tries or 0) + 1
				)
			end)
			return
		end
		if current_screen and current_screen.key == sc.key then
			return
		end
	elseif settings.screens[size .. '@0'] and not settings.screens[sc.key] then
		-- remembered without a refresh rate before: the same screen, now complete
		settings.screens[sc.key] = settings.screens[size .. '@0']
		settings.screens[sc.key].label = sc.label
		settings.screens[size .. '@0'] = nil
		save()
	end
	current_screen = sc
	if not settings.screens[sc.key] then
		local first = screen_count() == 0
		settings.screens[sc.key] =
			{ label = sc.label, seen = os.date('%Y-%m-%d'), hdr_peak = first and settings.hdr_peak or 'auto' }
		save()
		if not first and opts.write then
			notify('New screen: ' .. sc.label, 'F1: check its settings - HDR brightness, screen for upscaling', 10)
		end
	end
	apply_peak()
	publish()
	if open_type then
		send_menu(open_type, true)
	end
end

-- display-width/-height/-fps change together when the window moves to another
-- monitor or the mode changes: read them once they have settled
local screen_timer = nil
local function screen_changed()
	if screen_timer then
		screen_timer:kill()
	end
	screen_timer = mp.add_timeout(0.3, function()
		screen_timer = nil
		screen_seen(
			mp.get_property_number('display-width'),
			mp.get_property_number('display-height'),
			mp.get_property_number('display-fps')
		)
	end)
end
for _, prop in ipairs({ 'display-width', 'display-height', 'display-fps' }) do
	mp.observe_property(prop, 'number', screen_changed)
end

-- script-message-to settings screen-seen <W> <H> <Hz>: a screen as Windows would
-- report it (the tests: --vo=null has no display)
mp.register_script_message('screen-seen', function(w, h, fps)
	screen_seen(tonumber(w), tonumber(h), tonumber(fps))
end)

-- ---- the gear button in uosc's control bar (uosc.conf controls= button:settings) --------------
local function settings_button()
	local json = utils.format_json({
		icon = 'settings',
		tooltip = 'Settings - click: settings, right-click: welcome and every feature (F1)',
		command = { 'script-message-to', 'settings', 'open' },
		menu_command = { 'script-message-to', 'settings', 'open-welcome' },
	})
	if json then
		mp.commandv('script-message-to', 'uosc', 'set-button', 'settings', json)
	end
end
-- as the other managed buttons: uosc may load after this script
mp.add_timeout(0.5, settings_button)
