-- Real renderer, fullscreen: every shipped chain plays without a single
-- dropped, late or mistimed frame at 1x and at the speed keys' 3x
-- (AGENTS.md validation item 6), with its render time per frame reported.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function counters()
	return {
		mp.get_property_number('frame-drop-count', 0),
		mp.get_property_number('decoder-frame-drop-count', 0),
		mp.get_property_number('vo-delayed-frame-count', 0),
		mp.get_property_number('mistimed-frame-count', 0),
	}
end

local function render_ms()
	local vp = mp.get_property_native('vo-passes') or {}
	local avg, peak = 0, 0
	for _, p in ipairs(vp.fresh or {}) do
		avg = avg + (p.avg or 0)
		peak = peak + (p.peak or 0)
	end
	return avg / 1e6, peak / 1e6
end

local function measure(label, speed, seconds)
	mp.set_property_number('speed', speed)
	H.sleep(1.5) -- settle after the speed change
	local a = counters()
	H.sleep(seconds)
	local b = counters()
	local avg, peak = render_ms()
	H.info(string.format('%s @%gx: render %.2f ms avg / %.2f ms peak per frame', label, speed, avg, peak))
	H.check(
		string.format('%s @%gx: no dropped/late/mistimed frames in %g s', label, speed, seconds),
		b[1] == a[1] and b[2] == a[2] and b[3] == a[3] and b[4] == a[4],
		string.format(
			'vo drops %d, decoder drops %d, delayed %d, mistimed %d',
			b[1] - a[1],
			b[2] - a[2],
			b[3] - a[3],
			b[4] - a[4]
		)
	)
end

-- label, file, upscale mode, expected hwdec-current: d3d11va-copy for
-- FastStream files and local files alike (vulkan decoding lost the GPU device
-- on 2026-10-04 - mpv.conf's hwdec section)
-- Anime at 1080p (1.33x on 1440p: the most common FastStream anime stream and
-- the costliest Anime path) and at 480p (3x: the second Anime4K stage runs)
-- next to 720p (exactly 2x), since 2026-10-03.
local CASES = {
	{ 'Anime @720p (Auto)', 'gpu/anime720/ep#fs-content=anime&fs-id=1111111111111111.mkv', '1', 'd3d11va-copy' },
	{ 'Anime @1080p (Auto)', 'gpu/anime1080/ep#fs-content=anime&fs-id=4444444444444444.mkv', '1', 'd3d11va-copy' },
	{ 'Anime @480p (Auto)', 'gpu/anime480/ep#fs-content=anime&fs-id=5555555555555555.mkv', '1', 'd3d11va-copy' },
	{ 'Movie @720p', 'gpu/movie720/film#fs-content=movie&fs-id=2222222222222222.mkv', '3', 'd3d11va-copy' },
	{ 'Movie @1080p', 'gpu/movie1080/film#fs-content=movie&fs-id=3333333333333333.mkv', '3', 'd3d11va-copy' },
	{ 'Off @1080p', 'gpu/movie1080/film#fs-content=movie&fs-id=3333333333333333.mkv', '0', 'd3d11va-copy' },
	{ 'Movie @720p, local file', 'gpu/local720/film.mkv', '3', 'd3d11va-copy' },
}

H.run(function()
	H.eq('renderer is gpu-next', mp.get_property('current-vo'), 'gpu-next')
	H.eq('GPU context is Vulkan (winvk)', mp.get_property('current-gpu-context'), 'winvk')
	for _, c in ipairs(CASES) do
		mp.set_property_number('speed', 1)
		mp.commandv('script-message-to', 'gpu_toggles', 'set-upscale', c[3])
		H.load(H.media_path(c[2]))
		mp.commandv('seek', '0', 'absolute')
		H.sleep(1)
		H.eq(c[1] .. ': decoded with ' .. c[4], mp.get_property('hwdec-current'), c[4])
		measure(c[1], 1, 10)
		measure(c[1], 3, 6)
	end
	mp.set_property_number('speed', 1)
end, { timeout = 280 })
