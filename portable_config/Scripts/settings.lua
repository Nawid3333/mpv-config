-- settings.lua - the Settings menu, the Welcome menu (F1), and the settings that
-- differ from PC to PC.
--
-- The menus stay open, mark the recommended choice, and keep every option
-- selectable.
--
--   Settings (right-click menu > Settings, `script-message-to settings open`)
--   Welcome  (F1, Help, and the first start - Scripts/welcome.lua; `open-welcome`):
--            the same settings on top, then every feature with its key.
--
--   Buffering - FastStream's buffer options, with its names, meanings and
--     defaults (stream-buffer.lua does the buffering): predownload the whole
--     video (on), its maximum size (5 GB), RAM for buffered video (Auto by
--     this PC's memory), keep video on disk when that RAM is full (on), seconds
--     ahead (300) and behind (20). Every number also takes 0 (none) and no limit,
--     and any value typed in (Custom...). Start and stalls: Adaptive (the
--     default: start as soon as the line keeps up with the stream, and after a
--     stall wait by the line's speed - see adaptive_wait()), start at once, or
--     buffer N seconds first and after a stall (cache-pause-initial/-wait). A
--     seek never waits for it (see apply_buffer()).
--   Upscaling quality, screen, Movie sharpness - gpu-toggles.lua owns them (and
--     ~~state/upscale.json); its items come from user-data/gpu-toggles/quality.
--   HDR brightness - target-peak while an HDR (PQ/HLG) video plays: the screen's
--     peak in nits, which the tone mapping aims at. Auto = mpv's own default
--     (203 nits on an SDR desktop; with Windows HDR on, what the display
--     reports). SDR video always gets auto: a peak set for every file made SDR
--     ~78 % as bright.
--   Subtitle / audio language - mpv's slang / alang. Empty = mpv's own choice:
--     subtitles in Windows' display language when the audio is another one
--     (subs-match-os-language), the file's default audio track.
--
--   The screen - what Windows reports for the window's monitor (display-width x
--     display-height @ display-fps). Every screen seen is remembered with its own
--     HDR brightness; a new one starts at Auto (a peak tuned for one panel is
--     wrong for the next) and a banner names it, with F1 to check its settings.
--     The upscaling follows the screen by itself (gpu-toggles reads it per action;
--     the shader warm-up warms again for a new size).
--
-- Every setting explains itself in its submenu (a dimmed note on what it does,
-- a pro or con next to each option); a gear button in the control bar opens the
-- Settings, right-click the Welcome menu.
--
-- Stored per PC in ~~state/settings.json (gitignored). A PC that ran this
-- config before (any state file of it is there) keeps what mpv.conf gave it -
-- German, then English, 350 nits, 1 GB - so an update changes nothing there
-- (the start and stall wait is Adaptive everywhere: mpv.conf's 3 s gave way to
-- it); a new install starts from the recommended values.
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
-- written whole or not at all, and a damaged one kept aside (issue #96)
local statefile = dofile(mp.command_native({ 'expand-path', '~~/script-modules/state-file.lua' }))
-- a damaged settings.json that could not be moved aside: never saved over
local file_stuck = false

-- FastStream's buffer defaults (its DefaultOptions.mjs); ram_budget is Auto here
-- (by this PC's memory, FastStream's 2 GB from 16 GB on).
local BUFFERING = {
	download_all = true,
	max_video_size = 5e9,
	buffer_to_disk = true,
	buffer_ahead = 300,
	buffer_behind = 20,
}
-- What mpv.conf set for everyone (1 GB: the RAM budget now).
-- (start_wait: mpv.conf's 3 s gave way to Adaptive everywhere, at the owner's word.)
local LEGACY = { slang = 'de,en', alang = 'de,en', hdr_peak = 350, ram_budget = 1e9, start_wait = 'auto' }
local DEFAULTS = { slang = '', alang = '', hdr_peak = 'auto', ram_budget = 'auto', start_wait = 'auto' }
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
-- The choices offered for each number (sizes in bytes as FastStream counts them,
-- 1 GB = 1,000,000,000; -1 = no limit, FastStream's empty field); Custom... takes
-- any other.
local MAX_SIZES = { 0, 1e9, 2e9, 5e9, 10e9, 20e9, 50e9, -1 }
local RAM_SIZES = { 0, 150e6, 512e6, 1e9, 2e9, 4e9, 8e9, -1 }
local AHEADS = { 0, 30, 60, 120, 300, 600, 1800, -1 }
local BEHINDS = { 0, 20, 60, 300, 1800, -1 }
-- the old Buffering choices, as RAM budgets
local OLD_BUFFERS = { small = 150e6, medium = 512e6, large = 1e9, xlarge = 2e9, whole = 'auto', auto = 'auto' }
local WAITS = { 'auto', 0, 3, 5, 10 }

local function exists(path)
	return utils.file_info(mp.command_native({ 'expand-path', path })) ~= nil
end

-- A damaged file (no JSON table) counted as no file yet: the defaults were seeded and
-- saved over it at once, every per-PC choice gone without a word. It is kept aside as
-- settings.json.corrupt-<time> now, with a warning (issue #96).
local function read_file()
	local data, stuck = statefile.read_json(FILE, 'settings.json')
	file_stuck = stuck == true
	return data
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

-- A byte size or seconds: -1 (no limit) or 0 and up, whole numbers.
local function valid_amount(v, max)
	v = tonumber(v)
	if not v or v ~= v then
		return nil
	end
	v = math.floor(v)
	return (v == -1 or (v >= 0 and v <= max)) and v or nil
end

local function valid_size(v)
	return valid_amount(v, 1e14)
end

local function valid_secs(v)
	return valid_amount(v, 864000)
end

local function valid_ram(v)
	return v == 'auto' and v or valid_size(v)
end

local function valid_bool(v)
	if v == true or v == 'yes' or v == 'true' then
		return true
	elseif v == false or v == 'no' or v == 'false' then
		return false
	end
	return nil
end

local function valid_wait(v)
	if v == 'auto' then
		return v
	end
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

-- The RAM budget recommended for this PC: what is buffered waits in RAM
-- (compressed) up to it, the rest on disk; FastStream's 2 GB from 16 GB on.
local function recommended_ram()
	if not RAM_GB then
		return 512e6
	elseif RAM_GB < 6 then
		return 150e6
	elseif RAM_GB < 12 then
		return 512e6
	elseif RAM_GB < 16 then
		return 1e9
	end
	return 2e9
end

local settings = {}
local from_file = read_file()
local seeded = nil -- 'legacy' | 'defaults' when this start created the file
local migrated = false -- the old Buffering choice became the RAM budget this start
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
	-- the old Buffering choice is the RAM budget now
	local old = OLD_BUFFERS[src.buffer]
	settings.ram_budget = valid_ram(src.ram_budget) or old or base.ram_budget
	settings.download_all = valid_bool(src.download_all)
	if settings.download_all == nil then
		settings.download_all = BUFFERING.download_all
	end
	settings.buffer_to_disk = valid_bool(src.buffer_to_disk)
	if settings.buffer_to_disk == nil then
		settings.buffer_to_disk = BUFFERING.buffer_to_disk
	end
	settings.max_video_size = valid_size(src.max_video_size) or BUFFERING.max_video_size
	settings.buffer_ahead = valid_secs(src.buffer_ahead) or BUFFERING.buffer_ahead
	settings.buffer_behind = valid_secs(src.buffer_behind) or BUFFERING.buffer_behind
	-- the fixed wait from before: its default (3 s) is Adaptive now, a wait chosen by
	-- hand (start at once, 5 s, 10 s) stays
	local old_wait = valid_wait(src.buffer_wait)
	if old_wait == 3 then
		old_wait = 'auto'
	end
	settings.start_wait = valid_wait(src.start_wait) or old_wait or base.start_wait
	migrated = (old ~= nil and src.ram_budget == nil) or (src.buffer_wait ~= nil and src.start_wait == nil)
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

-- Whole or not at all (state-file.lua), as the other state files.
local function save()
	if not opts.write or file_stuck then
		return
	end
	local json = utils.format_json(settings)
	local ok, err = false, 'cannot serialize the settings'
	if json then
		ok, err = statefile.write(FILE, json)
	end
	if not ok then
		msg.warn(err)
	end
end

-- The decision is made once per PC: the next start must not take the legacy
-- values just because this session wrote speed.json.
if seeded or migrated then
	msg.verbose('settings.json: ' .. (seeded and ('new, from the ' .. seeded .. ' values') or 'buffering moved'))
	save()
end

local function effective_ram()
	return settings.ram_budget == 'auto' and recommended_ram() or settings.ram_budget
end

-- ---- applying ----------------------------------------------------------------------
-- Before the first file: mpv waits for every script's main chunk before it
-- opens one, so the first file already uses these.
local function apply_languages()
	mp.set_property('slang', settings.slang)
	mp.set_property('alang', settings.alang)
end

-- A seek starts at once. cache-pause-initial holds playback after EVERY seek,
-- not only at a file's start: mpv clears restart_complete on each seek
-- (player/playloop.c, reset_playback_state()), and handle_update_cache() then
-- waits for cache-pause-wait seconds of buffer whenever fewer are read - on a
-- stream, a seek past what is downloaded stalled until enough had arrived. So
-- the initial wait is on until this file's first start (playback-restart) and
-- off from then on. A stall still waits cache-pause-wait seconds: that path
-- needs no cache-pause-initial.
local started = false -- this file has started: its next restarts are seeks
local function apply_initial_wait()
	local w = settings.start_wait
	mp.set_property('cache-pause-initial', ((w == 'auto' or w > 0) and not started) and 'yes' or 'no')
end

-- What stream-buffer.lua buffers the next file with (user-data/settings/buffering,
-- read at that file's load).
local function buffering_config()
	return {
		download_all = settings.download_all,
		max_video_size = settings.max_video_size,
		ram_budget = effective_ram(),
		buffer_to_disk = settings.buffer_to_disk,
		buffer_ahead = settings.buffer_ahead,
		buffer_behind = settings.buffer_behind,
	}
end

-- Adaptive: how long to wait, from the line's speed. While mpv waits (before a
-- file plays, and in a stall) playback stands still, so the buffer grows by what
-- the line brings. q, the seconds of the stream per second, is the largest of
-- three readings, so the wait ends as soon as any of them says the line keeps up:
-- how far the buffer's end moved since this wait began (known at once; low before
-- the first frame, where the opening counts too), how far over the last
-- ADAPT_SLOPE_SECS, and mpv's raw-input-rate over the bytes the buffer holds per
-- second of the stream (0 for the first second; on HLS it runs ahead of the
-- buffer, which lags the line at the start). The end, not cache-duration: that
-- subtracts the reader, which the decoders move at the start, and it started some
-- HLS streams a second later. A line that keeps up (q >= ADAPT_FAST) waits
-- ADAPT_SHORT seconds of buffer (mpv's own stall default): no stall right after
-- the start, which starting at once had on HLS. A slower one waits for what
-- drains in ADAPT_PLAY_ON seconds: before the first frame never longer than the
-- old fixed 3 s (the video shows up soon), in a stall up to ADAPT_STALL_MAX - the
-- same total wait in fewer, longer pauses. Measured 2026-10-14 on a throttled line
-- (MP4, HLS with 4 and 10 s segments, 0.6x to 5x the stream). mpv compares the
-- buffer with cache-pause-wait on every update, so a lower value ends the wait at
-- once (player/playloop.c, handle_update_cache()).
local ADAPT_FAST = 1.2
local ADAPT_SHORT = 1
local ADAPT_UNKNOWN = 3
local ADAPT_START_MAX = 3
local ADAPT_STALL_MAX = 10
local ADAPT_PLAY_ON = 30
local ADAPT_SLOPE_SECS = 0.75
local adapt_timer = nil
local file_open = false
local played = false -- this file's first frame moved: a wait now is a stall
local adapt_since = nil -- when this file's load began
local wait_began = nil -- { time, the buffer's end (nil: the first one seen) } when this wait began
local adapt_samples = {} -- { time, the buffer's end } during this wait
local adapt_state = nil -- the last decision: { q, wait }
local line_stand_in = nil -- the tests' line (adaptive-line): a number, or false = unknown

-- seconds of the stream per second of the line, or nil
local function line_ratio()
	if line_stand_in ~= nil then
		return line_stand_in or nil
	end
	local s = mp.get_property_native('demuxer-cache-state')
	if type(s) ~= 'table' or s['seeking'] or not wait_began then
		return nil
	end
	local now, ends, ahead = mp.get_time(), s['cache-end'], s['cache-duration']
	if not ends or not ahead then
		return nil
	end
	local last = adapt_samples[#adapt_samples]
	-- a seek or a timestamp jump: measure anew
	if last and (ends < last[2] - 0.5 or ends > last[2] + 30) then
		adapt_samples = {}
		wait_began = { now, ends }
	end
	wait_began[2] = wait_began[2] or ends
	adapt_samples[#adapt_samples + 1] = { now, ends }
	while #adapt_samples > 1 and now - adapt_samples[1][1] > 2 * ADAPT_SLOPE_SECS do
		table.remove(adapt_samples, 1)
	end
	local q = nil
	if now - wait_began[1] >= 0.25 then
		q = (ends - wait_began[2]) / (now - wait_began[1])
	end
	local first = adapt_samples[1]
	if now - first[1] >= ADAPT_SLOPE_SECS then
		q = math.max(q or 0, (ends - first[2]) / (now - first[1]))
	end
	local fw, raw = s['fw-bytes'], s['raw-input-rate']
	if raw and raw > 0 and fw and fw > 0 and ahead >= 0.5 then
		q = math.max(q or 0, raw / (fw / ahead))
	end
	return q
end

local function adaptive_wait()
	local q = line_ratio()
	local w
	if not q then
		w = ADAPT_UNKNOWN
	else
		-- what drains in play_on seconds when the line brings q/ADAPT_FAST of the
		-- stream; a line that keeps up drains nothing and gets ADAPT_SHORT
		local play_on = ADAPT_PLAY_ON
		local left = (mp.get_property_number('duration') or 0) - (mp.get_property_number('time-pos') or 0)
		if left > 0 then
			play_on = math.min(play_on, left)
		end
		local most = played and ADAPT_STALL_MAX or ADAPT_START_MAX
		w = math.max(ADAPT_SHORT, math.min(most, play_on * (1 - q / ADAPT_FAST)))
	end
	adapt_state = { q = q, wait = w }
	local old = mp.get_property_number('cache-pause-wait')
	if not old or math.abs(old - w) >= 0.25 then
		mp.set_property_number('cache-pause-wait', w)
		msg.verbose(string.format('line %s the stream: wait %.1f s', q and string.format('%.2fx', q) or 'unknown', w))
	end
end

-- The timer runs while mpv waits: before the file plays, and in a stall.
local function update_adaptive()
	local waiting = settings.start_wait == 'auto'
		and file_open
		and (not played or mp.get_property_bool('paused-for-cache'))
	if waiting and not adapt_timer then
		adapt_samples = {}
		-- before the first frame the wait began at the load, from the first end seen
		if played then
			local s = mp.get_property_native('demuxer-cache-state')
			wait_began = { mp.get_time(), type(s) == 'table' and s['cache-end'] or nil }
		else
			wait_began = { adapt_since or mp.get_time(), nil }
		end
		adapt_timer = mp.add_periodic_timer(0.25, adaptive_wait)
		adaptive_wait()
	elseif not waiting and adapt_timer then
		adapt_timer:kill()
		adapt_timer = nil
	end
end

-- The waits apply at once (the sizes: publish(), for the next file).
local function apply_buffer()
	local wait = settings.start_wait
	apply_initial_wait()
	if wait == 'auto' then
		mp.set_property('cache-pause-wait', tostring(ADAPT_UNKNOWN))
	else
		mp.set_property('cache-pause-wait', tostring(wait > 0 and wait or 1))
	end
	update_adaptive()
end

mp.add_hook('on_load', 50, function()
	started = false
	played = false
	file_open = true
	adapt_since = mp.get_time()
	if settings.start_wait == 'auto' then
		mp.set_property('cache-pause-wait', tostring(ADAPT_UNKNOWN))
	end
	apply_initial_wait() -- the wait before this file's start
	update_adaptive()
end)

-- The first restart of a file is its start; every later one is a seek. The
-- initial wait, if any, runs after it (paused-for-cache); the first frame moves
-- when that ends.
mp.register_event('playback-restart', function()
	if not started then
		started = true
		played = not mp.get_property_bool('paused-for-cache')
		apply_initial_wait()
		update_adaptive()
	end
end)
mp.observe_property('paused-for-cache', 'bool', function(_, waiting)
	if started and not waiting then
		played = true
	end
	update_adaptive()
end)
mp.register_event('end-file', function()
	file_open = false
	update_adaptive()
end)

-- Tests stand in for the line: `script-message-to settings adaptive-line <q>` decides
-- as if the line brought q seconds of the stream per second, `none` as if no speed
-- were known yet; no argument measures again.
mp.register_script_message('adaptive-line', function(q)
	if q == 'none' then
		line_stand_in = false
	else
		line_stand_in = tonumber(q)
	end
	if settings.start_wait == 'auto' then
		adaptive_wait()
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

-- The HDR brightness for the screen the window is on; when no screen is known:
-- the PC-wide setting.
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
		buffering = buffering_config(),
		ram_budget = settings.ram_budget,
		ram_recommended = recommended_ram(),
		start_wait = settings.start_wait,
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

-- 5000000000 -> '5 GB', 150000000 -> '150 MB' (FastStream counts 1 GB = 10^9 bytes)
local function size_label(v)
	if v < 0 then
		return 'No limit'
	elseif v >= 1e9 then
		return (string.format('%.2f', v / 1e9):gsub('%.?0+$', '')) .. ' GB'
	end
	return string.format('%d MB', math.floor(v / 1e6 + 0.5))
end

local function secs_label(v)
	if v < 0 then
		return 'No limit'
	elseif v >= 120 and v % 60 == 0 then
		return string.format('%d s (%d min)', v, v / 60)
	end
	return string.format('%d s', v)
end

local function on_off(v)
	return v and 'On' or 'Off'
end

local function ram_label()
	local v = size_label(effective_ram())
	return settings.ram_budget == 'auto' and ('Auto (' .. v .. ')') or v
end

-- one line for the Buffering entry: what happens to a stream
local function buffer_label()
	local ram = effective_ram()
	local what = (settings.download_all and settings.max_video_size ~= 0) and 'Whole video'
		or (settings.buffer_ahead < 0 and 'Whole video' or (secs_label(settings.buffer_ahead) .. ' ahead'))
	local where
	if ram == 0 then
		where = settings.buffer_to_disk and 'on disk' or 'nothing kept'
	elseif ram < 0 then
		where = 'all in RAM'
	else
		where = size_label(ram) .. ' RAM' .. (settings.buffer_to_disk and ', then disk' or ' only')
	end
	return what .. ' · ' .. where
end

local function wait_label(w)
	if w == 'auto' then
		return 'adaptive'
	end
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

-- Any other value, typed in (mp.input, mpv's console line).
local function custom(key, value, listed, label)
	local items = {}
	if not listed then
		items[#items + 1] = { title = label(value), hint = 'typed in', active = true, keep_open = true }
	end
	items[#items + 1] = {
		title = 'Custom...',
		hint = 'type a value',
		value = { 'script-message-to', 'settings', 'custom', key },
		keep_open = true,
	}
	return items
end

-- a number setting: the notes, then each choice (its hint from `hints`), then Custom...
local function amount_items(key, notes, list, hints, label, current)
	local items = {}
	for i, n in ipairs(notes) do
		items[#items + 1] = note(n, i == #notes)
	end
	local listed = current == 'auto' -- the RAM budget's Auto is its own entry
	for _, v in ipairs(list) do
		listed = listed or v == current
		local title = v == 0 and ('0 - ' .. (hints.zero_title or 'none')) or label(v)
		items[#items + 1] = choice(title, hints[v], key, v, current == v)
	end
	for _, item in ipairs(custom(key, current, listed, label)) do
		items[#items + 1] = item
	end
	return items
end

local function on_off_items(key, notes, on_hint, off_hint)
	local items = {}
	for i, n in ipairs(notes) do
		items[#items + 1] = note(n, i == #notes)
	end
	items[#items + 1] = choice('On', on_hint, key, 'yes', settings[key] == true)
	items[#items + 1] = choice('Off', off_hint, key, 'no', settings[key] == false)
	return items
end

-- What stream-buffer.lua does with the stream playing now, if one does.
local function this_video_note()
	local b = mp.get_property_native('user-data/stream-buffer')
	if type(b) ~= 'table' or (b.storage ~= 'ram' and b.storage ~= 'disk') then
		return nil
	end
	local done = b.mode == 'predownload' and 'predownloading' or 'a window'
	return string.format(
		'This video: %s, %s in RAM, %s on disk',
		done,
		size_label(b.ram_bytes or 0),
		size_label(b.disk_bytes or 0)
	)
end

local function buffer_items()
	local ram = effective_ram()
	local rec = recommended_ram()
	local mem = RAM_GB and string.format('%.0f GB of RAM', RAM_GB) or 'memory unknown'
	local items = {
		note("FastStream's buffer settings, with its defaults."),
		note('Apply from the next video on.', true),
	}
	local now = this_video_note()
	if now then
		items[2].separator = nil
		items[#items + 1] = note(now, true)
	end
	local function sub(title, hint, list, separator)
		items[#items + 1] = { title = title, hint = hint, items = list, separator = separator }
	end
	sub(
		'Predownload the whole video',
		on_off(settings.download_all),
		on_off_items('download_all', {
			'Download the entire video in the background,',
			'up to the maximum size below.',
		}, "FastStream's default · no stalls once loaded", 'only the seconds ahead below')
	)
	sub(
		'Maximum size of predownloaded video',
		size_label(settings.max_video_size),
		amount_items(
			'max_video_size',
			{
				'Used only when predownload is on.',
				'Never more than 60 % of the free disk space.',
				'0: nothing predownloaded, only the seconds ahead.',
			},
			MAX_SIZES,
			{
				zero_title = 'predownload nothing',
				[5e9] = "FastStream's default",
				[-1] = 'the whole video, however big',
			},
			size_label,
			settings.max_video_size
		)
	)
	local ram_hints = {
		zero_title = 'none in RAM',
		[0] = settings.buffer_to_disk and 'all on disk but the next seconds' or 'nothing kept: may stop to load',
		[-1] = 'all in RAM, none on disk',
	}
	ram_hints[rec] = (ram_hints[rec] and (ram_hints[rec] .. ' · ') or '') .. 'recommended'
	local ram_list = amount_items('ram_budget', {
		'How much of the video is kept in RAM.',
		settings.buffer_to_disk and 'Beyond it the video goes on disk (below).'
			or 'Beyond it nothing more is kept (disk is off).',
		'No limit: all in RAM - on a PC with little memory',
		'other programs may slow down.',
	}, RAM_SIZES, ram_hints, size_label, settings.ram_budget)
	-- Auto first, after the notes
	local first = 1
	while ram_list[first] and ram_list[first].selectable == false do
		first = first + 1
	end
	table.insert(
		ram_list,
		first,
		choice(
			'Auto (recommended for this PC)',
			mem .. ' -> ' .. size_label(rec),
			'ram_budget',
			'auto',
			settings.ram_budget == 'auto',
			true
		)
	)
	sub('RAM for buffered video', ram_label(), ram_list)
	sub(
		'Keep video on disk when that RAM is full',
		on_off(settings.buffer_to_disk),
		on_off_items('buffer_to_disk', {
			'In a temp file, deleted when the video closes.',
			'Off: nothing is written to the disk; the buffer',
			'stops at the RAM above.',
		}, "FastStream's default", 'writes nothing to the disk')
	)
	sub(
		'Seconds ahead',
		secs_label(settings.buffer_ahead),
		amount_items(
			'buffer_ahead',
			{
				'Kept buffered ahead of playback when predownload',
				'is off, has stopped, or has run out of space.',
			},
			AHEADS,
			{
				zero_title = 'nothing ahead',
				[0] = 'the video stops to load often',
				[300] = "FastStream's default",
				[-1] = 'the whole video, even with predownload off',
			},
			secs_label,
			settings.buffer_ahead
		)
	)
	sub(
		'Seconds behind',
		secs_label(settings.buffer_behind),
		amount_items(
			'buffer_behind',
			{
				'Kept behind playback before trimming, while the',
				'whole video is not predownloaded (that keeps all).',
			},
			BEHINDS,
			{
				zero_title = 'drop at once',
				[0] = 'seeking back loads it again',
				[20] = "FastStream's default",
				[-1] = 'everything played is kept',
			},
			secs_label,
			settings.buffer_behind
		),
		true
	)
	items[#items + 1] = note('Not in mpv: a download speed limit, and how many')
	items[#items + 1] = note('downloads run at the same time.')
	return items
end

local WAIT_HINTS = {
	[0] = "mpv's default · fastest start, may stall early",
	[3] = 'a fixed wait at every start',
	[5] = 'smoother on a slow line',
	[10] = 'longest wait, fewest stalls',
}

-- What Adaptive did last: the line's speed and the wait it chose.
local function adaptive_hint()
	local st = adapt_state
	if not st or not st.q then
		return 'recommended · starts once the line keeps up'
	elseif st.wait <= ADAPT_SHORT then
		return string.format('recommended · now: line %.1fx the stream, starts at once', st.q)
	end
	return string.format('recommended · now: line %.1fx the stream, buffers %d s', st.q, math.floor(st.wait + 0.5))
end

local function wait_items()
	local items = {
		note('Wait for some seconds of video before playing,'),
		note('and again when the stream ran dry (a stall).'),
		note('Adaptive waits only as long as the line needs.'),
		note('A seek plays at once, without this wait.', true),
	}
	for _, w in ipairs(WAITS) do
		local title, hint
		if w == 'auto' then
			title, hint = 'Adaptive', adaptive_hint()
		else
			title = w > 0 and string.format('Buffer %d s first, and after a stall', w) or 'Start at once'
			hint = WAIT_HINTS[w]
		end
		items[#items + 1] = choice(title, hint, 'start_wait', w, settings.start_wait == w)
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
	sub('wait', 'Start and stalls', wait_label(settings.start_wait), wait_items(), true)
	if gpu and type(gpu.quality_items) == 'table' then
		sub('quality', 'Upscaling quality', gpu.label, gpu.quality_items)
		sub('screen', 'Screen for upscaling', gpu.screen_label, gpu.screen_items)
		sub('lines', 'Anime lines', gpu.anime_lines_label, gpu.anime_lines_items)
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
			hint = 'Shift+A, Shift+Y, Shift+S',
			items = {
				run('Anime upscaling on / off', 'Shift+A', 'script-binding gpu_toggles/toggle-anime'),
				run('Movie upscaling on / off', 'Shift+Y', 'script-binding gpu_toggles/toggle-movie'),
				run(
					'Anime lines / Movie sharpness: the next choice',
					'Shift+S',
					'script-binding gpu_toggles/cycle-tuning'
				),
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
				run(
					'Next episode: the page goes on, this window plays it',
					'Shift+N',
					'script-message faststream-next'
				),
				info('Previous episode', 'Shift+P'),
				info("Or the keyboard's media keys (next / previous track)", 'media keys'),
				info('A local file: the next / previous file of its folder', 'same keys'),
				info('At the end the next one follows (FastStream: Autoplay)', 'autoplay'),
				info('Stop that countdown, autoplay stays on', 'Space'),
				run('Autoplay next episode on / off', 'Ctrl+a', 'script-message faststream-autoplay'),
				info('Previous, next and autoplay are buttons in the bar too', 'toolbar'),
				run(
					'Stream, original page and file links, to copy',
					'source button',
					'script-message-to source_info open-menu'
				),
			},
		},
		{
			title = 'Window and information',
			hint = 'i, Ctrl+q',
			items = {
				info('Play / pause, fullscreen, menu', 'click / double / right'),
				run('File and stream information', 'i', 'script-binding stats/display-page-1'),
				info('Quit and keep the position', 'Ctrl+q'),
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
	download_all = function(v)
		v = valid_bool(v)
		if v == nil then
			return nil
		end
		settings.download_all = v
		return 'Predownload the whole video: ' .. on_off(v), 'from the next video on'
	end,
	max_video_size = function(v)
		v = valid_size(v)
		if not v then
			return nil
		end
		settings.max_video_size = v
		return 'Maximum size of predownloaded video: ' .. size_label(v), 'from the next video on'
	end,
	ram_budget = function(v)
		v = valid_ram(v)
		if not v then
			return nil
		end
		settings.ram_budget = v
		return 'RAM for buffered video: ' .. ram_label(), 'from the next video on'
	end,
	buffer_to_disk = function(v)
		v = valid_bool(v)
		if v == nil then
			return nil
		end
		settings.buffer_to_disk = v
		return 'Keep video on disk: ' .. on_off(v), 'from the next video on'
	end,
	buffer_ahead = function(v)
		v = valid_secs(v)
		if not v then
			return nil
		end
		settings.buffer_ahead = v
		return 'Seconds ahead: ' .. secs_label(v), 'from the next video on'
	end,
	buffer_behind = function(v)
		v = valid_secs(v)
		if not v then
			return nil
		end
		settings.buffer_behind = v
		return 'Seconds behind: ' .. secs_label(v), 'from the next video on'
	end,
	start_wait = function(v)
		v = valid_wait(v)
		if not v then
			return nil
		end
		settings.start_wait = v
		apply_buffer()
		return 'Start and stalls: ' .. wait_label(v), nil
	end,
}

local function set_value(key, value)
	local setter = SETTERS[key]
	local title, detail
	if setter then
		title, detail = setter(value)
	end
	if not title then
		msg.warn('set: invalid ' .. tostring(key) .. ' = ' .. tostring(value))
		-- a value typed into Custom... that the setting does not take: the prompt closed,
		-- and nothing said why nothing changed
		notify('Not changed', tostring(value) .. ' is not a value this setting takes', 3)
		return
	end
	save()
	publish()
	notify(title, detail)
	if open_type then
		send_menu(open_type, true)
	end
end

-- script-message-to settings set <key> <value>
mp.register_script_message('set', set_value)

-- ---- a value typed in (Custom...) -------------------------------------------------------
-- '3 GB', '800 MB', '1.5gb', '800' (MB); '' = no limit (FastStream's empty field)
local function parse_amount(text, units, default_unit)
	local t = (text or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
	if t == '' or t == '-1' or t == 'no limit' or t == 'unlimited' then
		return -1
	end
	local num, unit = t:match('^(%d+[%.,]?%d*)%s*(%a*)$')
	local mult = units[unit ~= '' and unit or default_unit]
	if not (num and mult) then
		return nil
	end
	return math.floor(tonumber((num:gsub(',', '.'))) * mult + 0.5)
end

local SIZE_UNITS = { kb = 1e3, mb = 1e6, m = 1e6, gb = 1e9, g = 1e9, tb = 1e12 }
local SECS_UNITS = { s = 1, sec = 1, m = 60, min = 60, h = 3600 }
local CUSTOM = {
	max_video_size = {
		prompt = 'Maximum size of predownloaded video (3 GB, 800 MB; 0 = nothing; empty = no limit):',
		units = SIZE_UNITS,
		unit = 'mb',
	},
	ram_budget = {
		prompt = 'RAM for buffered video (3 GB, 800 MB; 0 = none; empty = no limit):',
		units = SIZE_UNITS,
		unit = 'mb',
	},
	buffer_ahead = {
		prompt = 'Seconds ahead (90, 10 min; 0 = nothing; empty = no limit):',
		units = SECS_UNITS,
		unit = 's',
	},
	buffer_behind = {
		prompt = 'Seconds behind (90, 10 min; 0 = none; empty = no limit):',
		units = SECS_UNITS,
		unit = 's',
	},
}
local input_ok, input = pcall(require, 'mp.input')

-- script-message-to settings custom <key>
mp.register_script_message('custom', function(key)
	local c = CUSTOM[key]
	if not c then
		return
	end
	if not input_ok then
		notify('Typing a value needs a newer mpv', 'mp.input (mpv 0.38+)', 4)
		return
	end
	-- The menu closes while the line is open, and comes back when it closes (Enter
	-- or Esc): an open uosc menu has key bindings of its own (type to search),
	-- which would take what is typed.
	local reopen = open_type
	if reopen then
		mp.commandv('script-message-to', 'uosc', 'close-menu')
	end
	input.get({
		prompt = c.prompt .. ' ',
		submit = function(text)
			local v = parse_amount(text, c.units, c.unit)
			if not v then
				notify('Not understood: ' .. tostring(text), c.prompt, 5)
				return
			end
			input.terminate()
			set_value(key, tostring(v))
		end,
		closed = function()
			if reopen then
				open_menu(reopen)
			end
		end,
	})
end)

-- script-message-to settings parse <key> <text>: what Custom... would set (the tests)
mp.register_script_message('parse', function(key, text)
	local c = CUSTOM[key]
	mp.set_property_native('user-data/settings-parsed', c and parse_amount(text, c.units, c.unit) or 'invalid')
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
-- A screen seen for the first time is remembered; the very first one takes the
-- PC-wide HDR brightness, any later one starts at Auto and is announced.
local screen_retry = nil
local function screen_seen(w, h, fps, tries)
	local sc = screen_from(w, h, fps)
	if not sc or (current_screen and current_screen.key == sc.key) then
		return
	end
	-- The refresh rate can arrive a moment after the size: "2560x1440@0" would be
	-- remembered as a screen of its own, and the real "2560x1440@144" announced as
	-- new with its HDR brightness back at Auto.
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

-- ---- yt-dlp's JavaScript runtime --------------------------------------------------------------
-- mpv.conf has yt-dlp solve YouTube's challenges with Node.js (js-runtimes=node), which yt-dlp
-- looks for on PATH. The one-click install puts none there: the node.exe of its FastStream
-- helper is private (installer/install-faststream.ps1), so yt-dlp is pointed at that one when
-- it is there. Without it, a PC with no Node.js of its own got none of YouTube's formats that
-- need the challenges solved.
local function private_node()
	local base = os.getenv('LOCALAPPDATA')
	if not base or base == '' then
		return nil
	end
	local node = base .. '\\FastStreamMpvHost\\node\\node.exe'
	local info = utils.file_info(node)
	return info and info.is_file and node or nil
end
local node = private_node()
if node then
	local raw = mp.get_property_native('options/ytdl-raw-options') or {}
	raw['js-runtimes'] = 'node:' .. node
	mp.set_property_native('options/ytdl-raw-options', raw)
end

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
