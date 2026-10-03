-- shader-cache: keeps mpv's shader cache warm. Checked at every start; when it
-- went stale (new GPU driver, an mpv update - a new libplacebo means a full
-- warm-up, a new mpv alone a quick check - the cache folder cleared, shaders or
-- presets changed; fingerprint.lua has the list) it is rebuilt IN THE BACKGROUND
-- while the video plays, with a small progress bar top right. Nothing blocks:
-- the video starts as it always did.
--
-- History (2026-09-26): first built as a full-screen step before the video
-- (~45 s, then ~18 s); the user asked for no blocking and a small bar instead.
--
-- Every start: fingerprint.lua compares the stamp in the cache folder with the
-- current libplacebo version, display driver version (reg.exe, ~25 ms, no
-- console window: mpv spawns with CREATE_NO_WINDOW), shader files and cache
-- file count - off the playback path, nothing waits for it.
--
-- Stale: start_delay seconds after the video starts playing (so its own start
-- is not slowed), host.ps1 runs warmup.lua in a second mpv embedded in a window
-- that is never shown (host.ps1 says why each simpler way failed), at below-
-- normal priority, its clips paused except for a few stepped and played frames
-- per chain, so the GPU stays nearly idle. The chain the video uses compiles itself on its
-- first frame, as it always did; the warm-up covers every other chain and
-- scale tier, so a later switch or the next video does not hitch. Quitting
-- mpv ends the warm-up with it (it runs again next start). A failed or
-- timed-out one is not retried for the same fingerprint (shader-warmup.failed)
-- - installer\warm-shader-cache.ps1 runs it on request.
--
-- Capture (on by default): every shader real playback still had to compile is
-- noted in portable_config/shader-misses.log with what was on screen - how the
-- warm-up's clip list is checked against real use. See capture_scan().
-- Since 2026-10-02 each real gap is also LEARNED (cases.lua): stored title-free
-- in portable_config/shader-cases.json and replayed by every full warm-up, so
-- the next driver or libplacebo update rebuilds what real viewing needs, not
-- only the fixed clip list. The log written since 2026-09-26 is imported once.
-- "Shader capture status" in the menu shows what was learned.
--
-- State for tests and curious users: user-data/shader-cache.
local utils = require('mp.utils')
local msg = require('mp.msg')
local options = require('mp.options')
local fingerprint = dofile(utils.join_path(mp.get_script_directory(), 'fingerprint.lua'))
local cases = dofile(utils.join_path(mp.get_script_directory(), 'cases.lua'))

local opts = {
	auto = true, -- check at every start and warm in the background when stale
	start_delay = 1.5, -- seconds after the video starts before the warm-up does
	idle_delay = 2, -- mpv opened with no file: seconds of idle before it warms
	timeout = 270, -- seconds before a warm-up is abandoned
	capture = true, -- log shaders compiled during real playback (shader-misses.log)
	-- seconds after the last change before looking for new shaders: a cold chain
	-- compiles in ~0.5 s here, so each switch gets its own line
	capture_delay = 1,
	-- for tests/run-tests.ps1:
	warmup_vo = '', -- --vo for the warm-up process ('null' runs it headless)
	warmup_matrix = '', -- 'test' = one tiny clip
	warmup_script = '', -- another script in place of warmup.lua
}
options.read_options(opts, 'shader_cache')

local info = {}
local state
local function publish(s, extra)
	state = s or state
	info.state = state
	for k, v in pairs(extra or {}) do
		info[k] = v
	end
	mp.set_property_native('user-data/shader-cache', info)
end

local vo = mp.get_property('options/vo', '')
if vo ~= '' and not vo:find('gpu', 1, true) and opts.warmup_vo == '' then
	publish('off', { why = 'no gpu renderer (vo=' .. vo .. ')' })
	return
end
if mp.get_property('options/gpu-shader-cache') == 'no' then
	publish('off', { why = 'gpu-shader-cache=no' })
	return
end

-- ---- the bar, top right -----------------------------------------------------------
-- A Scripts/notify.lua banner with a progress line: notify draws every message
-- in this design (it started here), so they stack instead of overlapping.

local function show_bar(title, detail, frac, hide_after)
	mp.commandv(
		'script-message-to',
		'notify',
		'show',
		'shader-cache',
		title,
		detail or '',
		tostring(hide_after or 0),
		tostring(frac or 0)
	)
end

-- ---- the warm-up -------------------------------------------------------------------

local fp, job, started_at, stop_reason, poll, job_timeout
local lock_file = fingerprint.path(fingerprint.LOCK)
local progress_file = fingerprint.path('shader-warmup.progress')
local args_file = fingerprint.path('shader-warmup.args')

local function lock_is_fresh()
	local f = utils.file_info(lock_file)
	return f and (os.time() - f.mtime) < opts.timeout + 60
end

local function ensure_cache_dir()
	local dir = fingerprint.cache_dir()
	if not utils.file_info(dir) then
		mp.command_native({
			name = 'subprocess',
			args = { 'cmd', '/d', '/c', 'mkdir', (dir:gsub('/', '\\')) },
			playback_only = false,
		})
	end
end

local function write_lines(path, lines)
	local f = io.open(path, 'w')
	if not f then
		return false
	end
	f:write(table.concat(lines, '\n'), '\n')
	f:close()
	return true
end

-- ---- capture: what real playback still compiles ------------------------------------
--
-- The warm-up covers what its clip list plays. To learn what real use needs
-- beyond that, the player watches the cache folder: mpv stores every compiled
-- shader or pipeline as its own shader_<16 hex> file when it is made, so a new
-- file is a compile. capture_scan() lists the folder (~400 names, ~1 ms, in this
-- script's own thread) a few seconds after anything that can need new shaders
-- changed - file, video format, decoder, chain, sharpness, window size - and
-- once a minute, and appends what is new, with what was on screen, to
-- ~~state/shader-misses.log. Not libplacebo's debug log: that is ~2,000-3,000
-- formatted lines per chain switch, on the render thread. While a warm-up
-- (this player's or another's) writes to the folder, it only re-counts.
local capture_log = mp.command_native({ 'expand-path', '~~state/shader-misses.log' })
local known, known_ctx, known_case, capture_timer

local function chain_label()
	local names = {}
	for _, s in ipairs(mp.get_property_native('glsl-shaders') or {}) do
		names[#names + 1] = s:match('([^/\\]+)%.glsl$') or s
	end
	local all = table.concat(names, ' ')
	-- gpu-toggles.lua says which preset is on (2026-10-03); the file names are
	-- only the fallback for an older gpu-toggles that does not
	local family = mp.get_property_native('user-data/gpu-toggles/preset')
	local label = all
	if #names == 0 then
		label = 'no upscaler'
	elseif family == 'anime' or (family == nil and all:find('Anime4K', 1, true)) then
		label = 'Anime'
	elseif family == 'movie' or (family == nil and all:find('SSimSuperRes', 1, true)) then
		label = all:find('FSRCNNX', 1, true) and 'Movie (FSRCNNX+SSimSuperRes)' or 'Movie (SSimSuperRes)'
	end
	local sharpen = (mp.get_property_native('glsl-shader-opts') or {})['adaptive-sharpen/curve_height']
	-- the option stays set after leaving Movie; only Movie runs adaptive-sharpen
	return (sharpen and label:find('^Movie')) and (label .. ', sharpen ' .. sharpen) or label
end

local function context()
	local video = 'no video'
	local vp = mp.get_property_native('video-params')
	if vp then
		video = string.format(
			'%dx%d %s%s %s %s/%s, decoder %s',
			vp.w or 0,
			vp.h or 0,
			vp.pixelformat or '?',
			vp['hw-pixelformat'] and ('/' .. vp['hw-pixelformat']) or '',
			mp.get_property('current-tracks/video/codec', '?'),
			vp.colormatrix or '?',
			vp.gamma or '?',
			mp.get_property('hwdec-current', 'no')
		)
	end
	local w, h = mp.get_osd_size()
	return string.format(
		'%s | %s | %s | %dx%d %s',
		mp.get_property('media-title', '?'),
		video,
		chain_label(),
		w or 0,
		h or 0,
		mp.get_property_native('fullscreen') and 'fullscreen' or 'window'
	)
end

local function list_objects()
	local set = {}
	for _, f in ipairs(utils.readdir(fingerprint.cache_dir(), 'files') or {}) do
		if #f == 23 and f:match('^shader_%x+$') then
			set[f] = true
		end
	end
	return set
end

local function append_capture(line)
	local f_info = utils.file_info(capture_log)
	if f_info and f_info.size > 1024 * 1024 then
		return -- a diagnostic, never a disk filler
	end
	local f = io.open(capture_log, 'a')
	if f then
		f:write(line, '\n')
		f:close()
	end
end

-- baseline: only re-count (at start, after a warm-up)
local function capture_scan(baseline)
	capture_timer = nil
	local t0 = mp.get_time()
	local set = list_objects()
	local ctx = context()
	local case_now = cases.current(chain_label())
	if state == 'warming' or lock_is_fresh() then
		baseline = true -- a warm-up is writing here
	end
	if known and not baseline then
		local new = 0
		for f in pairs(set) do
			if not known[f] then
				new = new + 1
			end
		end
		if new > 0 then
			append_capture(string.format(
				'%s  +%d  %s%s  [cache %s]',
				os.date('%Y-%m-%d %H:%M:%S'),
				new,
				ctx,
				-- a compile right before a change belongs to the state before it
				(known_ctx and known_ctx ~= ctx and not known_ctx:find('| no video |', 1, true))
						and ('  (before: ' .. known_ctx .. ')')
					or '',
				tostring(state)
			))
			info.captured = (info.captured or 0) + new
			-- a real gap (the warm-up had run for this fingerprint): learn it,
			-- and the state before a change too, as the line above says
			if state == 'fresh' or state == 'done' then
				local learn = { case_now }
				if known_case and known_ctx ~= ctx and not known_case.idle then
					learn[#learn + 1] = known_case
				end
				local data = cases.load()
				local added = cases.merge(data, learn, os.date('%Y-%m-%d %H:%M:%S'))
				if cases.save(data) then
					info.learned = (info.learned or 0) + added
					info.cases = #data.cases
				end
			end
		end
	end
	known, known_ctx, known_case = set, ctx, case_now
	info.scan_ms = math.floor((mp.get_time() - t0) * 1000 + 0.5)
	publish()
end

local function capture_soon()
	if capture_timer then
		capture_timer:kill()
	end
	capture_timer = mp.add_timeout(opts.capture_delay, function()
		capture_scan(false)
	end)
end

-- warmup.lua writes "<done> <total>", what it draws, and its title.
local function read_progress()
	local f = io.open(progress_file, 'r')
	if not f then
		return
	end
	local first, detail, title = f:read('*l'), f:read('*l'), f:read('*l')
	f:close()
	local done, total = (first or ''):match('^(%d+) (%d+)$')
	done, total = tonumber(done), tonumber(total)
	if not done or not total or total <= 0 then
		return
	end
	local frac = done / total
	info.progress = { done = done, total = total, detail = detail }
	publish()
	-- A quick check that compiles nothing shows nothing (2026-10-02: every mpv
	-- update started with "Checking shaders" and "Shaders up to date"); the bar
	-- appears once it turns into compiling.
	if title == 'Checking shaders' then
		return
	end
	show_bar(string.format('%s  %d%%', title or 'Compiling shaders', math.floor(frac * 100)), detail, frac)
end

local function cleanup()
	if poll then
		poll:kill()
		poll = nil
	end
	if job_timeout then
		job_timeout:kill()
		job_timeout = nil
	end
	os.remove(lock_file)
	os.remove(progress_file)
	os.remove(args_file)
end

-- warmup.lua's own failure exits (its header): setup, timeout, stamp. Its 6
-- ("steps never drawn": a minimized window, a locked screen) is the moment's,
-- not the cache's: retried like an interruption since 2026-10-02 (it used to
-- count as failed for good, and nothing said so).
local WARMUP_FAILURES = { [2] = true, [3] = true, [4] = true }

local function finished(res)
	job = nil
	read_progress() -- the last state it reached, for user-data
	cleanup()
	local out = (res and res.stdout) or ''
	local summary = ''
	for line in out:gmatch('[^\r\n]+') do
		msg.verbose('warm-up: ' .. line)
		if line:match('^RESULT (%u+)') ~= 'INFO' or not line:match(': %d+ compiles$') then
			summary = line
		end
	end
	local status = res and res.status
	local result
	if stop_reason and res and res.killed_by_us then
		result = stop_reason
	elseif status == 0 and fingerprint.same(fingerprint.read(fingerprint.STAMP), fp) then
		result = 'done'
	elseif type(status) == 'number' and status ~= 0 and not WARMUP_FAILURES[status] then
		-- Ended from outside (taskkill /F gives exit 1 - the FastStream e2e tests
		-- kill every mpv.exe that starts during a spec - or a crash): retried at
		-- the next start, but a third time in a row for this fingerprint counts
		-- as a failure, so a warm-up that crashes every time cannot loop forever.
		local last = fingerprint.read(fingerprint.INTERRUPTED)
		local times = (fingerprint.same(last, fp) and tonumber(last.times) or 0) + 1
		result = times >= 3 and 'failed' or 'interrupted'
		fingerprint.write(fingerprint.INTERRUPTED, fp, nil, { times = times })
	else
		result = 'failed'
	end
	if result ~= 'interrupted' then
		fingerprint.remove(fingerprint.INTERRUPTED)
	end
	local seconds = mp.get_time() - started_at
	if result == 'interrupted' then
		msg.warn(
			'shader warm-up ended from outside (exit ' .. tostring(status) .. ') - it runs again at the next start'
		)
		show_bar('Shader compiling interrupted', 'continues at the next start', 1, 3)
	elseif result == 'failed' or result == 'timeout' then
		fingerprint.write(fingerprint.FAILED, fp)
		msg.warn(
			'shader warm-up '
				.. result
				.. ' ('
				.. tostring(res and (res.error_string ~= '' and res.error_string or res.status))
				.. ', '
				.. summary
				.. ') - not retried until the driver/mpv/shaders change; installer\\warm-shader-cache.ps1 runs it on request'
		)
		show_bar('Shader warm-up failed', 'Upscale menu > Rebuild shaders tries again', 1, 6)
	elseif result == 'done' then
		msg.info(string.format('shader warm-up done in %.1f s: %s', seconds, summary))
		-- A quick check that compiled nothing showed no bar, and says nothing now.
		if not summary:find('quick check', 1, true) then
			show_bar('Shaders ready', nil, 1, 2.5)
		end
	end
	publish(result, { seconds = seconds, summary = summary })
	if opts.capture then
		capture_scan(true) -- what the warm-up added is not a miss
	end
end

-- ---- learned cases: the old log once, and a status for the menu ---------------------

local function days_since(date)
	local y, mo, d, h, mi, sec = (date or ''):match('^(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)$')
	if not y then
		return nil
	end
	local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec })
	return math.max(0, math.floor((os.time() - t) / 86400))
end

local function publish_cases(data)
	data = data or cases.load()
	info.cases = #data.cases
	info.last_gap = data.last_gap
	publish()
end

-- The capture log written since 2026-09-26 holds the gaps found before
-- learning existed; its real gaps become cases once (title-free, see
-- cases.read_log). `import-log` repeats it on request (tests).
local function import_log(force)
	local data = cases.load()
	if data.imported and not force then
		return publish_cases(data)
	end
	local added = cases.import_log(data)
	if cases.save(data) then
		info.imported = added
		if added > 0 then
			msg.info(string.format('learned %d shader cases from shader-misses.log', added))
		end
	end
	publish_cases(data)
end
mp.register_script_message('import-log', function()
	import_log(true)
end)

local function start_warmup()
	if state ~= 'stale' then
		return
	end
	-- the old log's cases must be in the file before warmup.lua reads it
	import_log(false)
	if lock_is_fresh() then
		return publish('busy') -- another player is warming it right now
	end
	publish('warming')
	started_at = mp.get_time()
	-- This warm-up's own: an earlier one's timeout must not count for it.
	stop_reason = nil
	ensure_cache_dir()
	write_lines(lock_file, { tostring(mp.get_property('pid')) })
	os.remove(progress_file)

	local cfg = mp.command_native({ 'expand-path', '~~/' })
	local script = opts.warmup_script ~= '' and opts.warmup_script
		or utils.join_path(mp.get_script_directory(), 'warmup.lua')
	local lines = {
		utils.join_path(mp.command_native({ 'expand-path', '~~exe_dir/' }), 'mpv.exe'),
		'--load-scripts=no',
		'--script=' .. utils.join_path(cfg, 'Scripts/gpu-toggles.lua'),
		'--script=' .. utils.join_path(cfg, 'Scripts/uosc'),
		-- gpu-toggles announces each switch as a banner: drawn here as in the player
		'--script=' .. utils.join_path(cfg, 'Scripts/notify.lua'),
		'--script=' .. script,
		'--priority=belownormal',
		-- a stepped frame shows at once instead of after its 24 fps slot
		-- (measured: 92 ms per frame-step without it, 240 steps = 21 s)
		'--untimed',
		'--ao=null',
		'--force-window=yes',
		'--idle=yes',
		'--no-terminal',
		'--input-ipc-server=',
		'--gpu-shader-cache-dir=' .. fingerprint.cache_dir(),
		'--script-opts-append=shader_warmup-quick=' .. (info.mode == 'quick' and 'yes' or 'no'),
		-- it steps through the Movie sharpness levels: not the user's choice
		'--script-opts-append=gpu_toggles-remember=no',
	}
	if opts.warmup_vo ~= '' then
		lines[#lines + 1] = '--vo=' .. opts.warmup_vo
	end
	if opts.warmup_matrix ~= '' then
		lines[#lines + 1] = '--script-opts-append=shader_warmup-matrix=' .. opts.warmup_matrix
	end
	write_lines(args_file, lines)

	msg.info(
		'shader cache stale ('
			.. fingerprint.describe(info.reasons)
			.. ', '
			.. info.mode
			.. '), warming it in the background'
	)
	if info.mode ~= 'quick' then
		show_bar('Compiling shaders  0%', 'starting', 0)
	end
	job = mp.command_native_async({
		name = 'subprocess',
		args = {
			'powershell.exe',
			'-NoProfile',
			'-NonInteractive',
			'-ExecutionPolicy',
			'Bypass',
			'-File',
			utils.join_path(mp.get_script_directory(), 'host.ps1'),
			'-ArgsFile',
			args_file,
			'-Owner',
			mp.get_property('window-id') or '0',
		},
		playback_only = false,
		capture_stdout = true,
		capture_stderr = true,
	}, function(_, res)
		finished(res)
	end)
	poll = mp.add_periodic_timer(0.25, read_progress)
	-- Its own job only: a finished warm-up's timer fired into the next one (a
	-- "Rebuild shaders" within opts.timeout of it), aborted it as a timeout and
	-- left the cache empty (2026-10-02). finished() kills it too.
	local this_job = job
	job_timeout = mp.add_timeout(opts.timeout, function()
		if job and job == this_job and not stop_reason then
			stop_reason = 'timeout'
			mp.abort_async_command(job)
		end
	end)
end

-- ---- the check -----------------------------------------------------------------------

-- The warm-up waits for the first video to be playing (a stream's buffering,
-- decoder start and its own first compile go first). mpv opened with nothing
-- to play has no start to keep clear: it warms after a moment of idle (the
-- user opened an empty mpv, saw no bar and asked for exactly this).
local playing = false
local function when_playing()
	mp.add_timeout(opts.start_delay, start_warmup)
end
local function when_idle()
	mp.add_timeout(opts.idle_delay, function()
		-- a file opened meanwhile warms after its own start instead
		if not playing and mp.get_property_native('idle-active') then
			start_warmup()
		end
	end)
end
mp.register_event('playback-restart', function()
	if not playing then
		playing = true
		if state == 'stale' and opts.auto then
			when_playing()
		end
	end
end)

publish('checking')
local t0 = mp.get_time()
fingerprint.collect(function(result)
	fp = result
	local reasons, mode = fingerprint.compare(fingerprint.read(fingerprint.STAMP), fp, fingerprint.count_cache_files())
	local check = { check_ms = math.floor((mp.get_time() - t0) * 1000 + 0.5), fingerprint = fp }
	if not mode then
		return publish('fresh', check)
	end
	check.reasons, check.mode = table.concat(reasons, '+'), mode
	publish('stale', check)
	if not opts.auto then
		return
	end
	local failed = fingerprint.read(fingerprint.FAILED)
	if fingerprint.same(failed, fp) then
		msg.warn(
			'shader cache stale ('
				.. check.reasons
				.. ') but the last warm-up failed - Upscale menu > Rebuild shaders tries again'
		)
		-- Said once on screen, at the first start after the failure (2026-10-02: it
		-- was only in a log that a normal start does not write).
		if failed.told ~= 'yes' then
			show_bar('Shaders not compiled', 'the last attempt failed - Upscale menu > Rebuild shaders', 1, 6)
			fingerprint.write(fingerprint.FAILED, fp, nil, { told = 'yes' })
		end
		return publish('failed-before')
	end
	if playing then
		when_playing()
	else
		when_idle()
	end
end)

-- "Rebuild shaders" (menu: Video > Shaders, and the upscale button's menu):
-- deletes mpv's OWN compiled shaders - the shader_<16 hex> files in its cache
-- folder - and warms everything again at once, whatever the stamp says (also
-- after a failed attempt). AMD's driver cache (%LOCALAPPDATA%\AMD\VkCache)
-- is never touched; the driver keeps its own copies there as it does for
-- every Vulkan program.
local function rebuild()
	if state == 'warming' then
		return -- already compiling; its bar is showing
	end
	if lock_is_fresh() then
		return show_bar('Shaders are compiling', 'in another mpv window', 1, 3)
	end
	if not fp then
		return mp.add_timeout(0.2, rebuild) -- the start-up check answers in ~70 ms
	end
	local deleted = 0
	for name in pairs(list_objects()) do
		if os.remove(utils.join_path(fingerprint.cache_dir(), name)) then
			deleted = deleted + 1
		end
	end
	for _, name in ipairs({ fingerprint.STAMP, fingerprint.FAILED, fingerprint.INTERRUPTED }) do
		fingerprint.remove(name)
	end
	msg.info(string.format('rebuild from the menu: deleted %d compiled shaders', deleted))
	publish('stale', { reasons = 'manual', mode = 'full', deleted = deleted })
	start_warmup()
end
mp.register_script_message('rebuild', rebuild)

-- Quitting mpv ends the warm-up with it (mpv ends its subprocesses on exit,
-- and the warm-up quits when host.ps1's window goes); it runs again next time.
mp.register_event('shutdown', function()
	if state == 'warming' then
		stop_reason = stop_reason or 'quit'
		cleanup()
	elseif opts.capture then
		capture_scan(false)
	end
end)

-- "Shader capture status" (menu: Video > Shaders): what was learned, and how
-- long real viewing has gone without a new gap - a month without one counts
-- as the capture being filled.
mp.register_script_message('status', function()
	local data = cases.load()
	publish_cases(data)
	local detail
	if #data.cases == 0 then
		detail = opts.capture and 'no gap found yet · capture on' or 'capture off (shader_cache-capture=no)'
	else
		local days = days_since(data.last_gap)
		local since = days == nil and '?' or days == 0 and 'today' or days == 1 and 'yesterday' or (days .. ' days ago')
		detail = string.format('%d learned · newest gap %s', #data.cases, since)
		if days and days >= 30 then
			detail = string.format('%d learned · no new gap for %d days', #data.cases, days)
		end
	end
	mp.commandv('script-message-to', 'notify', 'show', 'shader-cache', 'Shader capture', detail, '5')
end)

if opts.capture then
	capture_scan(true)
	-- off the start-up path: a 1 MiB log parses in a few ms, but nothing waits
	mp.add_timeout(3, function()
		import_log(false)
	end)
	-- video-params' fields one by one: the whole table can change every frame
	-- (dynamic HDR metadata), which would keep postponing the scan
	for _, name in ipairs({
		'video-params/w',
		'video-params/h',
		'video-params/pixelformat',
		'video-params/colormatrix',
		'video-params/gamma',
		'hwdec-current',
		'glsl-shaders',
		'glsl-shader-opts',
		'fullscreen',
		'osd-dimensions',
	}) do
		mp.observe_property(name, 'native', capture_soon)
	end
	mp.add_periodic_timer(60, function()
		capture_scan(false)
	end)
end
