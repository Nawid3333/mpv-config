-- Shared by main.lua (the startup check in every player) and warmup.lua (the
-- warm-up process): what the shader cache has to match, and the stamp file
-- that records what it was last warmed for. Loaded with dofile(), not
-- require(): warmup.lua runs as a plain --script, outside this folder's
-- module path.
--
-- What makes cached shaders stale, measured 2026-09-26 (AGENTS.md has the
-- numbers): mpv's cache (portable_config/cache, shader_<16 hex> files) holds
-- two kinds of object - SPIR-V compiled from libplacebo's GLSL, keyed by that
-- GLSL, and the GPU driver's finished binaries (Vulkan pipeline cache blobs,
-- stamped with the driver's pipelineCacheUUID). So:
--   libplacebo version - new GLSL, new SPIR-V (an mpv update that keeps
--                        libplacebo, like 20260925 -> 20260926, compiled
--                        nothing: 0 of 80 warm-up steps)
--   display driver     - every binary blob is rejected; the driver recompiles
--   the cache folder   - deleted or thinned out
--   shaders + gpu-toggles.lua - what the chains are made of
--   mpv itself         - its render settings could change a pass; only a quick
--                        check (3 clips, ~1 s), escalating if anything compiled.
--                        A daily build of the same mpv commit (same version
--                        string, new FFmpeg only) triggers nothing.
-- Nothing else starts a warm-up: not a restart, a new video, a reboot or
-- resetting AMD's own shader cache.
-- AMD's own driver cache (%LOCALAPPDATA%\AMD\VkCache) is a second layer that
-- mpv does not control: with mpv's blobs removed it still answered every
-- pipeline in ~0.14 ms. Resetting it alone therefore costs mpv nothing.
local utils = require('mp.utils')

local M = {}

-- Bump when warmup.lua's clip matrix or way of drawing changes, so every cache
-- is re-warmed.
-- 2 (2026-09-26): each step also plays a few frames (warmup.lua play_frames).
-- 3 (2026-10-02): a full warm-up also replays the learned cases (cases.lua);
-- the bump re-warms once, with the cases imported from the capture log.
-- 4 (2026-10-02): a full warm-up also replays shipped-cases.lua, the gaps the
-- tests' gap hunt (run-tests.ps1 -Tier gaps) measured: HDR10, HLG, P3, film
-- grain, stills, 1:1 windows, 8K, the menu's video settings.
-- No bump on 2026-10-05, when the learned cases were removed: the warm-up then
-- draws less, and a cache warmed with them still holds everything it draws.
-- 5 (2026-10-09): every clip also with quality Fast (Anime4K's Fast set, Movie
-- without FSRCNNX), and clip sizes for the branches the standard ones miss on
-- this screen (warmup.lua add_screen_runs); the stamp records the screen.
M.WARMUP_VERSION = 5

-- The stamp and the control files live in the cache folder itself, so
-- clearing the cache clears the stamp too. mpv's own cleanup only ever
-- deletes shader_<16 hex> and icc_<16 hex> (vo_gpu_next.c cache_uninit), so
-- these names are safe there.
M.STAMP = 'shader-warmup.stamp'
M.FAILED = 'shader-warmup.failed'
M.LOCK = 'shader-warmup.lock'
M.INTERRUPTED = 'shader-warmup.interrupted'

-- Why a warm-up runs, for the log (user-data/shader-cache has the ids).
M.REASONS = {
	stamp = 'first run, or the shader cache was cleared',
	files = 'part of the shader cache was deleted',
	libplacebo = 'mpv was updated with a new libplacebo',
	driver = 'the GPU driver changed',
	warmup = 'the warm-up itself was updated',
	shaders = 'shaders or presets changed',
	mpv = 'mpv was updated',
	manual = 'rebuild chosen in the menu',
	display = 'mpv is on another screen size',
}

-- Same resolution as vo_gpu_next.c cache_init(): the option, else ~~cache/.
function M.cache_dir()
	local dir = mp.get_property('options/gpu-shader-cache-dir', '')
	if dir == '' then
		dir = '~~cache/'
	end
	return mp.command_native({ 'expand-path', dir })
end

function M.path(name)
	return utils.join_path(M.cache_dir(), name)
end

-- Compiled objects mpv has stored (shader_ + 16 hex digits).
function M.count_cache_files()
	local n = 0
	for _, f in ipairs(utils.readdir(M.cache_dir(), 'files') or {}) do
		if #f == 23 and f:match('^shader_%x+$') then
			n = n + 1
		end
	end
	return n
end

local function hash(s)
	local h = 0
	for i = 1, #s do
		h = (h * 31 + s:byte(i)) % 4294967296
	end
	return string.format('%08x', h)
end

-- The files the chains are built from, and mpv.conf. Name + size + mtime, not content: git
-- rewrites a file only when its content changes, and names (not full paths)
-- keep a copied config (tests/run-tests.ps1) matching the original.
local function config_signature()
	local shaders = mp.command_native({ 'expand-path', '~~/shaders' })
	local names = utils.readdir(shaders, 'files') or {}
	table.sort(names)
	local files = {}
	for _, name in ipairs(names) do
		if name:lower():match('%.glsl$') then
			files[#files + 1] = utils.join_path(shaders, name)
		end
	end
	files[#files + 1] = mp.command_native({ 'expand-path', '~~/Scripts/gpu-toggles.lua' })
	-- Its render options (scale, deband, target-peak, ...) change the passes of every
	-- chain (2026-10-02: an edit to it triggered no check at all).
	files[#files + 1] = mp.command_native({ 'expand-path', '~~/mpv.conf' })
	local parts = {}
	for _, path in ipairs(files) do
		local info = utils.file_info(path)
		if info then
			parts[#parts + 1] = string.format('%s:%d:%d', path:match('[^/\\]+$'), info.size, math.floor(info.mtime))
		end
	end
	return hash(table.concat(parts, ';'))
end

-- Every display adapter's driver version (reg.exe, ~25 ms). Unknown when the
-- query fails - then it simply never differs.
local DISPLAY_CLASS = 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}'
local function query_driver(cb)
	mp.command_native_async({
		name = 'subprocess',
		args = { 'reg', 'query', DISPLAY_CLASS, '/s', '/v', 'DriverVersion' },
		capture_stdout = true,
		capture_stderr = true,
		playback_only = false,
	}, function(_, res)
		local versions = {}
		for v in ((res and res.stdout) or ''):gmatch('DriverVersion%s+REG_SZ%s+(%S+)') do
			versions[#versions + 1] = v
		end
		table.sort(versions)
		cb(#versions > 0 and table.concat(versions, ',') or 'unknown')
	end)
end

local FIELDS = { 'libplacebo', 'driver', 'config', 'warmup', 'mpv' }

-- Calls cb(fp) with what the cache has to match right now.
function M.collect(cb)
	local fp = {
		libplacebo = mp.get_property('libplacebo-version', ''),
		config = config_signature(),
		warmup = tostring(M.WARMUP_VERSION),
		mpv = mp.get_property('mpv-version', ''),
	}
	query_driver(function(driver)
		fp.driver = driver
		cb(fp)
	end)
end

-- key=value lines; nil when the file does not exist.
function M.read(name)
	local f = io.open(M.path(name), 'r')
	if not f then
		return nil
	end
	local t = {}
	for line in f:lines() do
		local k, v = line:match('^([%w_]+)=(.*)$')
		if k then
			t[k] = v
		end
	end
	f:close()
	return t
end

function M.write(name, fp, files, extra)
	local lines = { '# what this shader cache was last warmed for - see Scripts/shader-cache' }
	for _, k in ipairs(FIELDS) do
		lines[#lines + 1] = k .. '=' .. tostring(fp[k] or '')
	end
	if files then
		lines[#lines + 1] = 'files=' .. files
	end
	for k, v in pairs(extra or {}) do
		lines[#lines + 1] = k .. '=' .. tostring(v)
	end
	lines[#lines + 1] = 'written=' .. os.date('%Y-%m-%d %H:%M:%S')
	local path = M.path(name)
	-- this process's own temp file: the players write .failed/.interrupted and
	-- a warm-up the stamp, possibly at the same moment
	local tmp = path .. '.' .. utils.getpid() .. '.tmp'
	local f = io.open(tmp, 'w')
	if not f then
		return false
	end
	f:write(table.concat(lines, '\n'), '\n')
	f:close()
	os.remove(path) -- rename does not replace on Windows
	if os.rename(tmp, path) == true then
		return true
	end
	os.remove(tmp)
	return false
end

function M.remove(name)
	os.remove(M.path(name))
end

-- The same fingerprint (a failed attempt is not retried until it changes).
function M.same(a, b)
	if not a or not b then
		return false
	end
	for _, k in ipairs(FIELDS) do
		if a[k] ~= b[k] then
			return false
		end
	end
	return true
end

-- Returns the reason ids and the warm-up mode: nil (current), 'quick' (only
-- the chain files changed - a few representative clips decide) or 'full'.
function M.compare(stamp, fp, files)
	if not stamp then
		return { 'stamp' }, 'full'
	end
	local reasons, mode = {}, 'quick'
	local function add(id, full)
		reasons[#reasons + 1] = id
		if full then
			mode = 'full'
		end
	end
	if (tonumber(stamp.files) or 0) > files then
		add('files', true)
	end
	if stamp.libplacebo ~= fp.libplacebo then
		add('libplacebo', true)
	end
	if stamp.driver ~= fp.driver then
		add('driver', true)
	end
	if stamp.warmup ~= fp.warmup then
		add('warmup', true)
	end
	if stamp.mpv ~= fp.mpv then
		add('mpv', false)
	end
	if stamp.config ~= fp.config then
		add('shaders', false)
	end
	if #reasons == 0 then
		return reasons, nil
	end
	return reasons, mode
end

function M.describe(ids)
	local out = {}
	for id in (ids or ''):gmatch('[^+]+') do
		out[#out + 1] = M.REASONS[id] or id
	end
	return table.concat(out, '; ')
end

return M
