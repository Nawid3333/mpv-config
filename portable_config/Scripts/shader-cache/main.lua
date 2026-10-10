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
-- History (2026-10-05): from 2026-09-26 the player also noted every shader real
-- playback still compiled (shader-misses.log), and from 2026-10-02 learned each
-- such gap as a case the warm-up replayed (cases.lua, shader-cases.json). The
-- owner's measurement (tests/run-tests.ps1 -Tier shadercost, mpv issue #39)
-- kept the warm-up and removed both: the fixed matrix plus shipped-cases.lua
-- is what the warm-up draws.
--
-- State for tests and curious users: user-data/shader-cache.
local utils = require('mp.utils')
local msg = require('mp.msg')
local options = require('mp.options')
local fingerprint = dofile(utils.join_path(mp.get_script_directory(), 'fingerprint.lua'))

local opts = {
	auto = true, -- check at every start and warm in the background when stale
	start_delay = 1.5, -- seconds after the video starts before the warm-up does
	idle_delay = 2, -- mpv opened with no file: seconds of idle before it warms
	timeout = 270, -- seconds before a warm-up is abandoned
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

-- mpv's own compiled shaders and pipelines: one shader_<16 hex> file each.
local function list_objects()
	local set = {}
	for _, f in ipairs(utils.readdir(fingerprint.cache_dir(), 'files') or {}) do
		if #f == 23 and f:match('^shader_%x+$') then
			set[f] = true
		end
	end
	return set
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
end

local function start_warmup()
	if state ~= 'stale' then
		return
	end
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
		-- the HDR brightness the player draws HDR video with (read-only here)
		'--script=' .. utils.join_path(cfg, 'Scripts/settings.lua'),
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
		'--script-opts-append=settings-write=no',
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
-- The screen the cache was warmed on (2026-10-09): which branches of the chains a
-- clip reaches depends on it, and warmup.lua adds clip sizes for the branches the
-- standard ones miss there. Known only once the window is up, so it is compared at
-- the first playback start, not with the rest. A stamp without a screen (written
-- before, or by a warm-up without one) never differs.
local function screen_changed()
	local stamp = fingerprint.read(fingerprint.STAMP)
	local w, h = mp.get_property_number('display-width'), mp.get_property_number('display-height')
	if not (stamp and stamp.display and w and h and w > 0 and h > 0) then
		return false
	end
	return stamp.display ~= string.format('%dx%d', w, h)
end

local function check_screen()
	-- a warm-up that failed for this fingerprint is not retried for a new screen
	-- either, as for every other reason (review, 2026-10-09: it started again at
	-- every start); Rebuild shaders in the menu still runs it
	if fingerprint.same(fingerprint.read(fingerprint.FAILED), fp) then
		return
	end
	if state == 'fresh' and opts.auto and screen_changed() then
		publish('stale', { reasons = 'display', mode = 'full' })
		when_playing()
	end
end

mp.register_event('playback-restart', function()
	if not playing then
		playing = true
		if state == 'stale' and opts.auto then
			when_playing()
		else
			check_screen()
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
		publish('fresh', check)
		if playing then
			check_screen()
		end
		return
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

-- "Rebuild shaders" (menu: Video > Upscale, and the upscale button's menu):
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
	end
end)
