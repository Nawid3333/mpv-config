-- shader cost: what EMPTY shader caches cost a viewer, next to warm ones.
--
-- run-tests.ps1 -Tier shadercost starts this once per case, state and
-- repeat, each time in a FRESH mpv (libplacebo also keeps what it compiled in
-- memory, so every run needs its own process):
--   cold   mpv's cache folder AND the AMD driver's own cache empty - the first
--          video of that kind after a GPU driver or libplacebo update, had
--          there been no warm-up (the worst case: nothing from an earlier
--          video helps)
--   again  the same file once more on what the cold run left in both caches
--          - every later video of that kind without a warm-up (mpv keeps
--          every shader it compiles; this proves it)
--   warm   a copy of the cache a full warm-up made (after both caches were
--          emptied) - what the player's background warm-up gives
-- The whole config (uosc, banners, every script), fullscreen, the real GPU,
-- started idle with a window, as FastStream starts mpv (--force-window), and
-- the file loaded by this script, so mpv's own start-up is not in the numbers.
-- NO log file: a log file raises libplacebo's log level, and each compile then
-- also writes out its shader's source, which real viewing never does - it
-- would make the cold numbers worse than they are.
--
-- Measured, in this order (the runner compares the states and applies the
-- decision rule, tests/README.md):
--   first frame   loadfile -> playback-restart. mpv reports a (re)start only
--                 once the first frame is on screen (player/video.c waits for
--                 it), so a compile that frame needed is inside this time.
--   windows       the first seconds of playback (a chain gpu-toggles sets
--                 after the first frame compiles here), then each action of
--                 the case with the seconds after it (a preset switch, a Movie
--                 sharpness level, a window size, fullscreen, a picture
--                 overlay, a Video menu setting). Per window: late frames
--                 (dropped by the VO or the decoder, or delayed), the longest
--                 pause between two frames (wall clock between time-pos
--                 changes - a compile stalls the render thread, so no new
--                 frame arrives), new shader objects in mpv's cache, and the
--                 shader chain and sharpness on screen at its end.
--   shaders       every new shader_<16 hex> object the process made
-- Checked, so a run that measured the wrong thing never counts: the upscale
-- preset on screen, the chain holds the shaders the case names (Movie:
-- FSRCNNX from 2x, the sharpener only when enlarged) and none it must not, no
-- renderer or script error. Results: RESULT lines, and one JSON file per run.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local utils = require('mp.utils')
local options = require('mp.options')

local o = { manifest = '' }
options.read_options(o, 'shader_cost')

-- Errors from any script or the renderer. Error level only: a lower level
-- would raise libplacebo's log level (see above).
local errors = {}
local self_name = mp.get_script_name()
mp.enable_messages('error')
mp.register_event('log-message', function(e)
	if (e.level == 'error' or e.level == 'fatal') and e.prefix ~= self_name then
		errors[#errors + 1] = e.prefix .. ': ' .. e.text
	end
end)

local cache_dir = mp.command_native({
	'expand-path',
	(
		mp.get_property('options/gpu-shader-cache-dir', '') ~= ''
			and mp.get_property('options/gpu-shader-cache-dir')
		or '~~cache/'
	),
})
local function cache_files()
	local n = 0
	for _, f in ipairs(utils.readdir(cache_dir, 'files') or {}) do
		if #f == 23 and f:match('^shader_%x+$') then
			n = n + 1
		end
	end
	return n
end

local function late_frames()
	return mp.get_property_number('frame-drop-count', 0)
		+ mp.get_property_number('decoder-frame-drop-count', 0)
		+ mp.get_property_number('vo-delayed-frame-count', 0)
end

-- The shader files running, by name, in order.
local function chain()
	local names = {}
	for _, p in ipairs(mp.get_property_native('glsl-shaders') or {}) do
		names[#names + 1] = p:match('([^/\\]+)%.glsl$') or p
	end
	return table.concat(names, ' ')
end

local function sharpness()
	return (mp.get_property_native('glsl-shader-opts') or {})['adaptive-sharpen/curve_height'] or ''
end

-- The longest wall-clock pause between two frames while a window is open.
local tracking, last_frame, longest = false, 0, 0
mp.observe_property('time-pos', 'number', function(_, v)
	if v == nil then
		return
	end
	local now = mp.get_time()
	if tracking then
		longest = math.max(longest, now - last_frame)
	end
	last_frame = now
end)

local function ms(seconds)
	return math.floor(seconds * 1000 + 0.5)
end

local function window(name, seconds, action)
	local late0, files0 = late_frames(), cache_files()
	longest, last_frame, tracking = 0, mp.get_time(), true
	if action then
		action()
	end
	H.sleep(seconds)
	tracking = false
	-- a pause still going on when the window closes counts too
	longest = math.max(longest, mp.get_time() - last_frame)
	local w = {
		name = name,
		late = late_frames() - late0,
		gap_ms = ms(longest),
		files = cache_files() - files0,
		chain = chain(),
		sharpness = sharpness(),
	}
	H.info(string.format('%s: %d late frames, longest pause %d ms, %d new shaders', name, w.late, w.gap_ms, w.files))
	return w
end

local function applied()
	return mp.get_property_number('user-data/gpu-toggles/applied', 0)
end

local function set_upscale(mode)
	local target = applied() + 1
	mp.commandv('script-message-to', 'gpu_toggles', 'set-upscale', mode)
	H.wait_until(function()
		return applied() >= target
	end, 3, 0.01)
end

-- What a viewer does mid-video, by kind (the runner's case list names them).
local ACTIONS = {
	-- the upscale menu / Shift+A / Shift+Y: 0 Off, 2 Anime, 3 Movie
	upscale = function(v)
		mp.commandv('script-message-to', 'gpu_toggles', 'set-upscale', v)
	end,
	-- the upscale menu's Movie sharpness: 0 (Off), 0.5, 1, 1.5 or auto
	sharpness = function(v)
		mp.commandv('script-message-to', 'gpu_toggles', 'set-movie-sharpness', v)
	end,
	fullscreen = function(v)
		mp.set_property_native('fullscreen', v == 'yes')
	end,
	['window-scale'] = function(v)
		mp.set_property_native('window-maximized', false)
		mp.set_property_number('window-scale', tonumber(v) or 1)
	end,
	maximize = function()
		mp.set_property_native('window-maximized', true)
	end,
	-- an RGBA picture over the video: thumbfast's timeline thumbnails and
	-- picture subtitles (PGS, VobSub) are drawn this way
	overlay = function(v)
		mp.commandv('overlay-add', '1', '40', '40', v, '0', 'bgra', '64', '64', '256')
	end,
	-- a Video menu setting, "name=value"
	property = function(v)
		local name, value = v:match('^([^=]+)=(.*)$')
		mp.set_property(name, value)
	end,
}

local function write(path, r)
	local f = io.open(path, 'w')
	if f then
		f:write(utils.format_json(r) or '{}', '\n')
		f:close()
	end
end

H.run(function()
	local fh = io.open(o.manifest, 'r')
	local c = fh and utils.parse_json(fh:read('*a') or '') or nil
	if fh then
		fh:close()
	end
	local readable = H.check('the case is readable', type(c) == 'table' and c.path and c.out, o.manifest)
	-- type() again, not only the check's result: lua-language-server narrows c
	-- (no longer nil) from a type() test, not from a function's return value
	if not readable or type(c) ~= 'table' then
		return
	end
	local r = {
		label = c.label,
		state = c.state,
		windows = {},
		mpv = mp.get_property('mpv-version', ''),
		libplacebo = mp.get_property('libplacebo-version', ''),
	}
	local name = string.format('%s (%s %s)', c.label, c.state, tostring(c['repeat'] or 1))
	local valid = true
	local function check(what, cond, detail)
		local ok = H.check(name .. ': ' .. what, cond, detail) and true or false
		valid = valid and ok
		return ok
	end

	-- the upscale setting before the file, as the menu leaves it (1 = Auto:
	-- a FastStream file gets its preset when it loads)
	set_upscale(c.mode)
	r.files_before = cache_files()
	local restarted_at
	local function on_restart()
		restarted_at = restarted_at or mp.get_time()
	end
	mp.register_event('playback-restart', on_restart)
	local t0 = mp.get_time()
	mp.commandv('loadfile', c.path, 'replace')
	local ok = H.wait_until(function()
		return restarted_at ~= nil
	end, 30, 0.01)
	mp.unregister_event(on_restart)
	check('plays', ok, 'no first frame within 30 s')
	if not ok then
		r.valid = false
		write(c.out, r)
		return
	end
	r.first_ms = ms(restarted_at - t0)
	H.info(string.format('%s: first frame after %d ms', name, r.first_ms))
	local start_s, action_s = tonumber(c.start_seconds) or 3, tonumber(c.action_seconds) or 2
	r.windows[#r.windows + 1] = window(string.format('first %g s of playback', start_s), start_s)

	-- native: user-data is a node, get_property() would return it JSON-quoted
	r.preset = mp.get_property_native('user-data/gpu-toggles/preset') or '?'
	r.chain = chain()
	r.sharpness = sharpness()
	r.hwdec = mp.get_property('hwdec-current', '?')
	r.video = string.format('%dx%d', mp.get_property_number('dwidth', 0), mp.get_property_number('dheight', 0))
	r.display =
		string.format('%dx%d', mp.get_property_number('display-width', 0), mp.get_property_number('display-height', 0))
	check('upscale preset on screen', r.preset == c.preset, 'got ' .. tostring(r.preset) .. ', want ' .. c.preset)
	if c.preset == 'off' then
		check('no shader chain', r.chain == '', r.chain)
	end
	for _, s in ipairs(c.expect or {}) do
		check('the chain has ' .. s, r.chain:find(s, 1, true) ~= nil, r.chain)
	end
	for _, s in ipairs(c.absent or {}) do
		check('the chain has no ' .. s, r.chain:find(s, 1, true) == nil, r.chain)
	end
	-- the scale the video is shown at (gpu-toggles' display scale), and Movie by
	-- its rule: FSRCNNX from 2x, the sharpener (Auto) only when enlarged
	local dw, dh = mp.get_property_number('display-width'), mp.get_property_number('display-height')
	local vw, vh = mp.get_property_number('dwidth'), mp.get_property_number('dheight')
	if dw and dh and vw and vh and vw > 0 and vh > 0 then
		r.scale = math.min(dw / vw, dh / vh)
	end
	if c.preset == 'movie' and check('display and video size known', r.scale ~= nil, r.display .. ' / ' .. r.video) then
		local function has(s)
			return r.chain:find(s, 1, true) ~= nil
		end
		local s = r.scale
		check(
			string.format('Movie at %.2fx: FSRCNNX %s', s, s >= 2 and 'on' or 'off'),
			has('FSRCNNX') == (s >= 2),
			r.chain
		)
		check(
			string.format('Movie at %.2fx: the sharpener %s', s, s > 1 and 'on' or 'off'),
			has('adaptive-sharpen') == (s > 1),
			r.chain
		)
	end
	H.info(
		string.format(
			'%s: video %s on %s, decoded with %s; chain: %s%s',
			name,
			r.video,
			r.display,
			r.hwdec,
			r.chain ~= '' and r.chain or 'none',
			r.sharpness ~= '' and (', sharpness ' .. r.sharpness) or ''
		)
	)

	for _, a in ipairs(c.actions or {}) do
		local act = ACTIONS[a.kind]
		if act then
			r.windows[#r.windows + 1] = window(a.name, action_s, function()
				act(a.value)
			end)
		else
			check('knows the action ' .. tostring(a.kind), false, a.name)
		end
	end
	r.files = cache_files() - r.files_before
	r.errors = errors
	H.info(string.format('%s: %d new shaders in all', name, r.files))
	check('no renderer or script errors', #errors == 0, table.concat(errors, ' | '))
	r.valid = valid
	write(c.out, r)
end, { wait_file = false })
