-- tests/lib/shader-cache.lua - shared by the shader-cache tests. The startup
-- check starts with the player and the warm-up runs in the background after the
-- video starts, so this records user-data/shader-cache and the start of
-- playback from the moment mpv loads the test script.
local utils = require('mp.utils')

local R = { states = {}, t = {}, info = {}, t0 = mp.get_time() }

mp.observe_property('user-data/shader-cache', 'native', function(_, v)
	if type(v) ~= 'table' then
		return
	end
	R.info = v
	if v.state and R.states[#R.states] ~= v.state then
		R.states[#R.states + 1] = v.state
		R.t[v.state] = R.t[v.state] or mp.get_time()
	end
end)
mp.register_event('playback-restart', function()
	R.t.playing = R.t.playing or mp.get_time()
end)

function R.saw(state)
	return R.t[state] ~= nil
end

function R.seq()
	return table.concat(R.states, ' > ')
end

-- H.run's body starts 0.3 s after file-loaded; with the real renderer the
-- first frame (window, chain) can come later than that. Call before any
-- check that reads R.t.playing.
function R.wait_playing(H, timeout)
	return H.wait_until(function()
		return R.t.playing ~= nil
	end, timeout or 15)
end

-- Waits for the background warm-up to end (done, failed or timeout).
local ENDS = { done = true, failed = true, timeout = true }
function R.wait_end(H, timeout)
	H.wait_until(function()
		return ENDS[R.info.state] ~= nil
	end, timeout or 30)
	return R.info.state
end

-- Seconds from the script's load until playback started.
function R.until_playing()
	return R.t.playing and (R.t.playing - R.t0) or math.huge
end

-- the folder main.lua uses: --gpu-shader-cache-dir, else ~~cache/
local dir_opt = mp.get_property('options/gpu-shader-cache-dir', '')
local cache = mp.command_native({ 'expand-path', dir_opt ~= '' and dir_opt or '~~cache/' })
function R.path(name)
	return utils.join_path(cache, name)
end

function R.exists(name)
	return utils.file_info(R.path(name)) ~= nil
end

-- main.lua's control files, all gone once no warm-up runs
function R.leftovers()
	local left = {}
	for _, f in ipairs({ 'lock', 'progress', 'args' }) do
		if R.exists('shader-warmup.' .. f) then
			left[#left + 1] = 'shader-warmup.' .. f
		end
	end
	return left
end

function R.read_stamp()
	local f = io.open(R.path('shader-warmup.stamp'), 'r')
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

-- Rewrites the stamp from the fingerprint the check saw, with `changes`
-- applied - how a phase sets up the next process's situation.
function R.write_stamp(changes)
	local fp = R.info.fingerprint or {}
	local t = {
		libplacebo = fp.libplacebo,
		driver = fp.driver,
		config = fp.config,
		warmup = fp.warmup,
		mpv = fp.mpv,
		files = '0',
	}
	for k, v in pairs(changes or {}) do
		t[k] = v
	end
	local f = assert(io.open(R.path('shader-warmup.stamp'), 'w'))
	for _, k in ipairs({ 'libplacebo', 'driver', 'config', 'warmup', 'mpv', 'files' }) do
		f:write(k, '=', tostring(t[k]), '\n')
	end
	f:close()
end

-- A made-up cache object, as mpv writes one per compiled shader - how the
-- capture tests fake a compile (a --vo=null player compiles nothing).
function R.fake_object()
	local name = string.format('shader_%08x%08x', os.time() % 4294967296, math.random(0, 2147483647))
	local f = assert(io.open(R.path(name), 'wb'))
	f:write('test')
	f:close()
	return name
end

-- The learned cases (portable_config/shader-cases.json, cases.lua).
local cases_file = mp.command_native({ 'expand-path', '~~state/shader-cases.json' })
function R.cases_text()
	local f = io.open(cases_file, 'r')
	if not f then
		return ''
	end
	local text = f:read('*a') or ''
	f:close()
	return text
end

function R.read_cases()
	return utils.parse_json(R.cases_text()) or {}
end

-- Sets the learned cases for the next process; marked imported, so the old
-- log is not read into it again.
function R.write_cases(list)
	local f = assert(io.open(cases_file, 'w'))
	f:write(utils.format_json({ version = 1, imported = 'test', cases = list }))
	f:close()
end

-- The capture log's last line (portable_config/shader-misses.log).
function R.last_capture()
	local f = io.open(mp.command_native({ 'expand-path', '~~state/shader-misses.log' }), 'r')
	if not f then
		return nil
	end
	local last
	for line in f:lines() do
		last = line
	end
	f:close()
	return last
end

return R
