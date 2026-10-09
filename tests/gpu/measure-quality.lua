-- Upscaling quality High vs Fast on this GPU and output size (2026-10-09, open
-- item 6d in AGENTS.md): what gpu-toggles' own measurement records for each
-- Anime and Movie chain (the code path quality Auto decides with), a direct
-- vo-passes reading next to it, and the frames dropped/late while each ran.
-- Then Auto itself, from nothing measured: does it switch to Fast where High
-- does not fit?
--
-- Run by hand on a real renderer (not part of a tier), one clip per process:
--   mpv --script=tests/gpu/measure-quality.lua <clip> [--fs | --geometry=WxH+0+0 --border=no]
--       [--vulkan-device=<name>] [--script-opts-append=gpu_toggles-...]
-- with ~~state/upscale.json removed first (so every chain is measured anew).
-- Prints RESULT INFO lines; the numbers are the result, nothing passes or fails
-- except "the chain ran" and "Auto ...".
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local PLAY = 6 -- seconds per chain: gpu-toggles measures after 3, the frame counts cover all of it

local function send(...)
	mp.commandv('script-message-to', 'gpu_toggles', ...)
end

local function quality()
	return mp.get_property_native('user-data/gpu-toggles/quality') or {}
end

local function chain()
	local names = {}
	for _, p in ipairs(mp.get_property_native('glsl-shaders') or {}) do
		local _, name = utils.split_path(p)
		names[#names + 1] = name
	end
	return table.concat(names, ';')
end

local function render_ms()
	local vp = mp.get_property_native('vo-passes') or {}
	local ns = 0
	for _, pass in ipairs(vp.fresh or {}) do
		ns = ns + (tonumber(pass.avg) or 0)
	end
	return ns / 1e6
end

local function counters()
	return {
		drop = mp.get_property_number('frame-drop-count', 0),
		delayed = mp.get_property_number('vo-delayed-frame-count', 0),
		mistimed = mp.get_property_number('mistimed-frame-count', 0),
	}
end

-- Runs one chain for PLAY seconds and reports it. `id` is gpu-toggles' chain id
-- (nil: the Movie chain gpu-toggles picked).
local function run(label, id, quality_value, mode)
	send('set-quality', quality_value)
	send('set-upscale', mode)
	H.sleep(0.5)
	local before = counters()
	H.sleep(PLAY)
	local after = counters()
	send('publish-quality')
	H.sleep(0.3)
	local q = quality()
	-- Movie's chain depends on the scale and the quality: ask what ran
	id = id or q.movie
	local measured = (q.costs or {})[id]
	H.info(
		string.format(
			'%s (%s): gpu-toggles measured %s ms, vo-passes %.1f ms, budget %.1f ms; dropped %d, delayed %d, mistimed %d over %d s | %s',
			label,
			id,
			measured and string.format('%.1f', measured) or 'nothing',
			render_ms(),
			q.budget_ms or 0,
			after.drop - before.drop,
			after.delayed - before.delayed,
			after.mistimed - before.mistimed,
			PLAY,
			chain()
		)
	)
	return measured
end

H.run(function()
	local d = mp.get_property_native('osd-dimensions') or {}
	H.info(
		string.format(
			'output %dx%d, display %sx%s, video %sx%s @ %s fps, gpu-context %s',
			d.w or 0,
			d.h or 0,
			mp.get_property('display-width', '?'),
			mp.get_property('display-height', '?'),
			mp.get_property('width', '?'),
			mp.get_property('height', '?'),
			mp.get_property('container-fps', '?'),
			mp.get_property('current-gpu-context', '?')
		)
	)
	send('forget-measurements')
	H.sleep(0.3)
	local high = run('Anime High', 'anime-high', 'high', '2')
	local fast = run('Anime Fast', 'anime-fast', 'fast', '2')
	run('Movie High', nil, 'high', '3')
	run('Movie Fast', nil, 'fast', '3')
	H.check('Anime High and Fast were both measured', high ~= nil and fast ~= nil)

	-- Auto from nothing measured: High first, measured; Fast once High does not fit,
	-- measured; off once Fast does not fit either (two measurements: 2 x PLAY)
	send('forget-measurements')
	send('set-quality', 'auto')
	send('set-upscale', '2')
	H.sleep(2 * PLAY)
	send('publish-quality')
	H.sleep(0.3)
	local q = quality()
	local hq = (q.costs or {})['anime-high']
	local fq = (q.costs or {})['anime-fast']
	local budget = q.budget_ms or 0
	local want = 'off'
	if hq and hq <= budget then
		want = 'anime-high'
	elseif fq and fq <= budget then
		want = 'anime-fast'
	end
	H.eq(
		string.format(
			'Auto (High %s ms, Fast %s ms, budget %.1f ms) runs %s',
			hq and string.format('%.1f', hq) or '?',
			fq and string.format('%.1f', fq) or '-',
			budget,
			want
		),
		q.anime,
		want
	)
end, { timeout = 150 })
