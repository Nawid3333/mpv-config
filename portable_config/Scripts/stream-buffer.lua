-- stream-buffer.lua - how a stream is buffered, the way FastStream does it
-- (2026-10-12, at the user's request: "give it the same configurable settings like
-- FastStream has ... so I have the same choices of freedom and even can decide no
-- RAM or no disk or no nothing"). The settings are FastStream's, with its names,
-- meanings and defaults; settings.lua shows them (Settings > Buffering), keeps them
-- in settings.json and publishes them as user-data/settings/buffering:
--
--   download_all   Predownload the whole video (on). Stops at max_video_size.
--   max_video_size Bytes predownloaded at most (5 GB; 0 = nothing predownloaded,
--                  only buffer_ahead; -1 = no limit). Never more than 60 % of the
--                  temp drive's free space, as FastStream.
--   ram_budget     Bytes of the video kept in RAM (Auto by the PC's memory; 0 = none;
--                  -1 = no limit, all in RAM).
--   buffer_to_disk Beyond the RAM budget the video goes on disk (on); off: nothing is
--                  written, the buffer stops at the budget.
--   buffer_ahead   Seconds read ahead when predownload is off, has stopped or ran out
--                  of space (300; 0 = nothing ahead; -1 = no limit).
--   buffer_behind  Seconds kept behind playback while the buffer is a window (20; 0 =
--                  dropped at once; -1 = all). While the whole video is predownloaded
--                  nothing is trimmed (FastStream keeps a video that fits).
--
-- How mpv does it (measured 2026-10-11 on the pinned build with a 61-minute, 2.9 GB
-- HLS stream; see the PR): a stream starts in RAM (demuxer-max-bytes). Just BEFORE
-- the RAM budget is full, cache-on-disk is switched on: the RAM part stays, new
-- packets go to a temp file in %TEMP% and count only their metadata (~70 MB per
-- hour of video) against demuxer-max-bytes, which is raised at the switch and again
-- whenever the metadata nears it - unraised, reading stopped just past the RAM part.
-- Before, not at, the limit: a demuxer that sits idle at its limit reads its new
-- options only when playback takes a packet, i.e. not while paused. So the RAM
-- limit itself sits HEADROOM above the budget, and the switch comes a margin below
-- it (a burst can take the RAM up to HEADROOM past the budget). Predownload =
-- cache-secs at mpv's own "no limit"; a window = cache-secs at buffer_ahead.
-- The temp file is unlinked as soon as it is made (mpv's default
-- demuxer-cache-unlink-files=immediate): not visible while in use, and gone when
-- the video closes, even after a crash. It only grows (mpv reuses no space in it),
-- so a window on disk after the maximum size keeps adding what it reads; below
-- LOW_DISK of free space the rest of the video stays in RAM instead.
-- Behind is mpv's demuxer-max-back-bytes, in bytes: seconds x the stream's bitrate.
-- On disk that counts metadata, so more than the seconds stays seekable there - at
-- no cost, mpv's temp file keeps what it read until the video closes anyway.
-- A live stream (no duration, or a growing one, for 3 s) has no end to predownload
-- to: a window.
--
-- Reviews (2026-10-12, deepseek-v4.1-flash and glm-5.3-flash through the PC's
-- Ollama): the headroom above the switch and a margin from the fastest growth, the
-- metadata limit raised again, the disk guard, the live check over several ticks
-- (it decided on the first), a floor for reading ahead with RAM only and its limit
-- lowered at once, no free-space cap when nothing goes to disk, and a local file's
-- ahead + behind within the budget came from them. With buffer_ahead at no limit
-- the maximum size stops nothing: FastStream's rule ("the whole video is
-- downloaded ahead, even with predownload off").
--
-- Not in mpv (FastStream has them): a download speed limit and the number of
-- downloads at the same time. A local file is read from its own disk: it gets
-- mpv's default 150 MB ahead / 50 MB behind, both within the RAM budget, and never
-- a disk copy of itself.
local mp = require('mp')
local msg = require('mp.msg')
local options = require('mp.options')

local opts = {
	-- tests: a local file is buffered as a stream (no test serves HTTP)
	local_is_stream = false,
	-- MB the RAM limit sits above the budget; the tests take 0, so that a local file
	-- (read at once) reaches the limit and the demuxer's wake-up after the switch is seen
	headroom_mb = 64,
}
options.read_options(opts, 'stream_buffer')

local MiB = 1048576
local HUGE_BYTES = 1024 * 1024 * MiB -- "no limit" for a byte option (1 TiB)
local HUGE_SECS = 3600000 -- mpv's own default for cache-secs (1000 hours)
-- demuxer-max-bytes on top of the RAM part once on disk: metadata only, ~70 MB per
-- hour of a 24 fps video with audio; raised again before the metadata reaches it
local META = 1024 * MiB
local LOCAL_AHEAD, LOCAL_BACK = 150 * MiB, 50 * MiB -- mpv's defaults
local MIN_AHEAD = 4 * MiB
local AHEAD_FLOOR_SECS = 10 -- RAM only: what stays for reading ahead, whatever is kept behind
local LOW_DISK = 2e9 -- below this much free space nothing more goes on disk
local LIVE_TICKS = 12 -- no duration, or a growing one, for 3 s: a live stream
local TICK = 0.25
local HEADROOM = opts.headroom_mb * MiB -- the RAM limit above the budget: the switch never waits on an idle demuxer

-- FastStream's defaults; settings.lua publishes the real values
local DEFAULTS = {
	download_all = true,
	max_video_size = 5e9,
	ram_budget = 1e9,
	buffer_to_disk = true,
	buffer_ahead = 300,
	buffer_behind = 20,
}

local function config()
	local c = mp.get_property_native('user-data/settings/buffering')
	local out = {}
	for k, v in pairs(DEFAULTS) do
		-- not `cond and c[k] or v`: that gives v for a setting that is false
		if type(c) == 'table' and type(c[k]) == type(v) then
			out[k] = c[k]
		else
			out[k] = v
		end
	end
	return out
end

local NETWORK = {
	http = true,
	https = true,
	ytdl = true,
	edl = true,
	rtmp = true,
	rtmps = true,
	rtsp = true,
	ftp = true,
	sftp = true,
	smb = true,
	dav = true,
	davs = true,
	nfs = true,
	srt = true,
	udp = true,
	rtp = true,
	mms = true,
	mmsh = true,
}
local function is_stream(path)
	local scheme = type(path) == 'string' and path:match('^(%a[%w+.-]*)://')
	return scheme ~= nil and NETWORK[scheme:lower()] == true
end

-- -1 = no limit
local function limit(v)
	return v < 0 and math.huge or v
end

local function bytes(v)
	return string.format('%d', math.min(math.max(math.floor(v), 0), HUGE_BYTES))
end

local function fset(name, value)
	mp.set_property('file-local-options/' .. name, value)
end

-- Free bytes on the drive of `dir` (LuaJIT FFI; Windows), or nil.
local ffi_ok, ffi = pcall(require, 'ffi')
---@type (fun(dir: string, avail: any, total: any, free: any): integer)|nil
local free_space_fn = nil
if ffi_ok and ffi.os == 'Windows' then
	pcall(function()
		ffi.cdef([[
			int GetDiskFreeSpaceExA(const char *dir, uint64_t *avail, uint64_t *total, uint64_t *free);
		]])
		free_space_fn = ffi.load('kernel32').GetDiskFreeSpaceExA
	end)
end
local function free_space(dir)
	-- the drive's root: always plain ASCII, whatever the user folder is called
	local root = type(dir) == 'string' and dir:match('^(%a:[/\\])')
	if not (free_space_fn and root) then
		return nil
	end
	local avail = ffi.new('uint64_t[1]')
	local ok, res = pcall(free_space_fn, root, avail, nil, nil)
	if not ok or res == 0 then
		return nil
	end
	return tonumber(avail[0])
end

local TEMP = os.getenv('TEMP') or os.getenv('TMP') or ''

-- ---- the current stream -----------------------------------------------------------------
local st_now = nil -- the stream's state while one plays
local timer = nil

local function publish()
	local st = st_now
	if not st then
		mp.set_property_native('user-data/stream-buffer', { storage = 'none' })
		return
	end
	mp.set_property_native('user-data/stream-buffer', {
		storage = st.storage, -- 'ram' | 'disk' | 'none' (nothing kept) | 'local'
		mode = st.mode, -- 'predownload' | 'window'
		reason = st.reason, -- why a window: 'off' | 'size' | 'live' | 'disk full'
		ram_budget = st.R < math.huge and st.R or -1,
		cap = st.cap < math.huge and st.cap or -1,
		ram_bytes = st.ram or 0,
		disk_bytes = st.disk_bytes or 0,
		downloaded = st.downloaded or 0,
		switched_at = st.switched_at,
		back_limit = st.back_limit,
		disk_full = st.disk_full,
	})
end

-- The stream's bytes per second: what mpv measures from the packets, else what the
-- RAM buffer holds per second of video, else 1 MB/s (8 Mbps) until one is known.
local function rate()
	local v = (mp.get_property_number('video-bitrate') or 0) + (mp.get_property_number('audio-bitrate') or 0)
	if v > 0 then
		return v / 8
	end
	local s = mp.get_property_native('demuxer-cache-state')
	if st_now and st_now.storage == 'ram' and type(s) == 'table' and s['seekable-ranges'] then
		local secs = 0
		for _, r in ipairs(s['seekable-ranges']) do
			secs = secs + math.max((r['end'] or 0) - (r.start or 0), 0)
		end
		if secs > 5 and (s['total-bytes'] or 0) > 0 then
			return s['total-bytes'] / secs
		end
	end
	return 1e6
end

-- RAM only: what stays for reading ahead, whatever is kept behind (at most half the
-- budget): 10 s of the stream - 4 MB were under a second of a 60 Mbps stream.
local function ahead_floor(st)
	return math.max(MIN_AHEAD, math.min(st.R / 2, AHEAD_FLOOR_SECS * rate()))
end

local function ram_only(st)
	return (not st.disk or st.disk_full) and st.R < math.huge
end

-- demuxer-max-back-bytes: everything while the whole video is predownloaded, else
-- buffer_behind seconds; with nothing on disk never more than the RAM budget minus
-- what reading ahead needs.
local function update_back(st)
	local want
	if st.mode == 'predownload' or st.behind < 0 then
		want = HUGE_BYTES
	else
		want = st.behind * rate()
	end
	if ram_only(st) then
		want = math.min(want, math.max(st.R - ahead_floor(st), 0))
	end
	local old = st.back_limit
	-- a small change is not worth a new limit (it is an estimate)
	if old and old > 0 and want > 0 and math.abs(want - old) / old < 0.2 then
		return
	end
	st.back_limit = math.floor(want)
	fset('demuxer-max-back-bytes', bytes(want))
end

-- Seconds ahead, as mpv's options. 0 is 0 and only no limit (-1, an empty field) is
-- none (the owner's rule, 2026-10-12): cache-secs 0 still left mpv's own 1 s read-ahead
-- (demuxer-readahead-secs), so that goes to 0 too.
local function set_ahead(seconds)
	fset('cache-secs', tostring(seconds < 0 and HUGE_SECS or seconds))
	if seconds == 0 then
		fset('demuxer-readahead-secs', '0')
	end
end

-- From now on a window: buffer_ahead seconds ahead, buffer_behind behind.
local function to_window(st, reason)
	st.mode = 'window'
	st.reason = reason
	set_ahead(st.ahead)
	st.back_limit = nil
	update_back(st)
	msg.verbose('window from now on (' .. reason .. ')')
end

local function set_limit(st, value)
	st.limit = value
	fset('demuxer-max-bytes', bytes(value))
end

-- The RAM budget is (about to be) full: the rest goes on disk.
local function to_disk(st, ram_now)
	st.storage = 'disk'
	st.ram = ram_now
	st.switched_at = ram_now
	-- raised first: the new packets count only their metadata, on top of the RAM part
	set_limit(st, ram_now + META)
	fset('cache-on-disk', 'yes')
	msg.verbose(string.format('RAM budget reached at %.0f MB: on disk from now on', ram_now / 1e6))
end

-- Too little disk left: what comes now stays in RAM (mpv keeps the file's old part).
local function disk_full(st, total, fw)
	st.disk_full = true
	fset('cache-on-disk', 'no')
	if st.mode == 'predownload' then
		to_window(st, 'disk full')
	end
	local room = st.R < math.huge and math.max(st.R - st.ram, ahead_floor(st)) or HUGE_BYTES
	st.fw_limit = fw + room
	set_limit(st, total + room)
	msg.warn('less than 2 GB free on the temp drive: the rest of this video stays in RAM')
end

local function tick()
	local st = st_now
	if not st or st.storage == 'none' or st.storage == 'local' then
		return
	end
	local s = mp.get_property_native('demuxer-cache-state')
	if type(s) ~= 'table' then
		return
	end
	local total, fw = s['total-bytes'] or 0, s['fw-bytes'] or 0
	local now = mp.get_time()
	-- how fast the buffer grows: how early before the budget to switch
	local grow = 0
	if st.last_total and now > st.last_time then
		grow = math.max(total - st.last_total, 0) / (now - st.last_time)
	end
	st.last_total, st.last_time = total, now
	-- the fastest growth seen: a burst after a quiet tick is covered too (glm's review)
	st.max_grow = math.max(st.max_grow or 0, grow)
	st.ticks = (st.ticks or 0) + 1

	if st.storage == 'ram' then
		st.ram = total
		st.disk_bytes = 0
	else
		st.disk_bytes = s['file-cache-bytes'] or 0
	end
	st.downloaded = st.ram + st.disk_bytes

	-- live: for LIVE_TICKS ticks in a row no duration, or one that grows. mpv reports
	-- the cached end as the duration of a source that has none (measured: an endless
	-- lavfi source said 1.96 s after 2 s), so "no duration" alone never came; a VOD's
	-- duration stands still from its start. Decided once: a paused live stream stops
	-- growing too, and switching back would only flip between the two.
	local dur = mp.get_property_native('duration')
	if total > 0 and (dur == nil or (st.last_dur and dur > st.last_dur + 0.01)) then
		st.live_ticks = (st.live_ticks or 0) + 1
	else
		st.live_ticks = 0
	end
	st.last_dur = dur
	if st.mode == 'predownload' and st.live_ticks >= LIVE_TICKS then
		to_window(st, 'live')
	end
	if st.mode == 'predownload' and st.downloaded >= st.cap then
		to_window(st, 'size')
	end

	if st.storage == 'ram' and st.R < math.huge and st.disk then
		-- switch while the demuxer still reads: 2 ticks of the fastest growth, at least 32 MB
		local margin = math.max(32 * MiB, st.max_grow * TICK * 2)
		if total >= st.R - margin then
			to_disk(st, total)
		end
	elseif st.storage == 'disk' and not st.disk_full then
		-- the metadata nears its limit: raise it while the demuxer still reads
		if total > st.limit - META / 2 then
			set_limit(st, total + META)
		end
		if st.ticks % 20 == 0 then
			local free = free_space(TEMP)
			if free and free < LOW_DISK then
				disk_full(st, total, fw)
			end
		end
	end
	if ram_only(st) and not st.disk_full then
		-- RAM only: ahead + behind within the budget (mpv limits the two apart)
		-- lower at once, raise only by more than 5 % (a stale limit let RAM drift over the
		-- budget - glm's review)
		local ahead = math.max(st.R - (total - fw), ahead_floor(st))
		if not st.fw_limit or ahead < st.fw_limit or ahead - st.fw_limit > math.max(st.fw_limit * 0.05, MiB) then
			st.fw_limit = ahead
			set_limit(st, ahead)
		end
	end
	update_back(st)
	publish()
end

local function stop()
	if timer then
		timer:kill()
		timer = nil
	end
	st_now = nil
end

mp.add_hook('on_load', 50, function()
	stop()
	local c = config()
	local path = mp.get_property('path')
	local R = limit(c.ram_budget)
	if not (is_stream(path) or opts.local_is_stream) then
		-- read from its own disk: mpv's defaults, ahead + behind within the RAM budget
		-- (RAM 0: no cache, mpv's 1 s read-ahead - a byte limit of 0 would leave it nothing)
		if R == 0 then
			fset('cache', 'no')
		end
		fset('demuxer-max-bytes', bytes(math.max(math.min(LOCAL_AHEAD, R * 0.75), MIN_AHEAD)))
		fset('demuxer-max-back-bytes', bytes(math.min(LOCAL_BACK, R * 0.25)))
		st_now = { storage = 'local', mode = 'window', reason = 'local', R = R, cap = math.huge }
		publish()
		return
	end
	local predownload = c.download_all and c.max_video_size ~= 0
	local st = {
		R = R,
		disk = c.buffer_to_disk,
		ahead = c.buffer_ahead,
		behind = c.buffer_behind,
		cap = math.huge,
		ram = 0,
		disk_bytes = 0,
		downloaded = 0,
	}
	st_now = st
	if predownload then
		st.cap = limit(c.max_video_size)
		if st.disk and R < math.huge then
			-- what goes on disk: never more than 60 % of the free space (FastStream)
			local free = free_space(TEMP)
			if free then
				st.cap = math.min(st.cap, free * 0.6)
			end
		elseif R < math.huge then
			st.cap = math.min(st.cap, R) -- nothing on disk: the room is RAM
		end
	end
	if R == 0 and not st.disk then
		-- no RAM, no disk: nothing kept, nothing read ahead - mpv's own 1 s read-ahead
		-- too (FastStream: "nothing is downloaded ahead of playback")
		st.storage = 'none'
		st.mode = 'window'
		st.reason = 'off'
		fset('cache', 'no')
		fset('demuxer-readahead-secs', '0')
		publish()
		return
	end
	fset('cache', 'yes')
	fset('demuxer-cache-dir', TEMP)
	if predownload then
		st.mode = 'predownload'
		fset('cache-secs', tostring(HUGE_SECS))
	else
		st.mode = 'window'
		st.reason = 'off'
		set_ahead(st.ahead)
	end
	if R == 0 then
		-- no RAM: on disk from the start
		st.storage = 'disk'
		st.switched_at = 0
		fset('cache-on-disk', 'yes')
		set_limit(st, META)
	else
		st.storage = 'ram'
		fset('cache-on-disk', 'no')
		-- RAM, then disk: the limit HEADROOM above the budget, so the switch below it
		-- comes while the demuxer still reads; RAM only: the budget itself
		set_limit(st, (st.disk and R < math.huge) and R + HEADROOM or R)
	end
	update_back(st)
	publish()
	timer = mp.add_periodic_timer(TICK, tick)
end)

mp.register_event('end-file', function()
	stop()
	publish()
end)

publish()
