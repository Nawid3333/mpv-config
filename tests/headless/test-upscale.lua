-- gpu-toggles.lua logic: which shader chain is loaded for each mode, key,
-- menu message and file type. Headless (--vo=null) there is no display, so
-- the display scale is unknown and Movie resolves to its SSimSuperRes chain
-- with sharpening at 1.0 - the scale-dependent pick (FSRCNNX at >= 2x) is
-- covered by tests/gpu/test-switching.lua in the real renderer.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local ANIME = table.concat({
	'Anime4K_Clamp_Highlights.glsl',
	'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
	'Anime4K_AutoDownscalePre_x2.glsl',
	'Anime4K_AutoDownscalePre_x4.glsl',
	'Anime4K_Restore_CNN_M.glsl',
	'Anime4K_Upscale_CNN_x2_M.glsl',
}, ';')
local MOVIE = 'SSimSuperRes.glsl;CfL_Prediction.glsl;adaptive-sharpen.glsl'
local MOVIE_NO_SHARPEN = 'SSimSuperRes.glsl;CfL_Prediction.glsl'
local OFF = ''

-- Loaded chain as "a.glsl;b.glsl" (file names only).
local function chain()
	local names = {}
	for _, p in ipairs(mp.get_property_native('glsl-shaders') or {}) do
		local _, name = utils.split_path(p)
		names[#names + 1] = name
	end
	return table.concat(names, ';')
end

local function curve_height()
	return (mp.get_property_native('glsl-shader-opts') or {})['adaptive-sharpen/curve_height']
end

local function dscale()
	return mp.get_property('dscale')
end

-- what gpu-toggles publishes for the shader cache's capture (2026-10-03)
local function family()
	return mp.get_property_native('user-data/gpu-toggles/preset')
end

local function send(...)
	mp.commandv('script-message-to', 'gpu_toggles', ...)
	H.sleep(0.15)
end

local function binding(name)
	mp.commandv('script-binding', 'gpu_toggles/' .. name)
	H.sleep(0.15)
end

H.run(function()
	local base_dscale = mp.get_property('dscale')

	-- ---- local file, fresh process (mode Auto) ----
	H.expect('local file + Auto -> no shaders', chain, OFF)
	H.expect('... published as preset off', family, 'off')

	binding('cycle-upscale')
	H.expect('cycle on a local file skips Auto: Off -> Anime', chain, ANIME)
	H.expect('... published as preset anime', family, 'anime')
	H.expect('Anime keeps the startup dscale', dscale, base_dscale)
	binding('cycle-upscale')
	H.expect('cycle: Anime -> Movie', chain, MOVIE)
	H.expect('... published as preset movie', family, 'movie')
	H.expect('Movie sets dscale=ewa_lanczossharp', dscale, 'ewa_lanczossharp')
	H.expect('Movie sharpening Auto at unknown scale = 1.000', curve_height, '1.000')
	binding('cycle-upscale')
	H.expect('cycle: Movie -> Off', chain, OFF)
	H.expect('... published as preset off again', family, 'off')
	H.expect('Off restores the startup dscale', dscale, base_dscale)
	binding('cycle-upscale')
	H.expect('cycle: Off -> Anime again (Auto skipped)', chain, ANIME)

	-- ---- Shift+A / Shift+Y through input.conf ----
	send('set-upscale', '0')
	H.key('Shift+A')
	H.expect('Shift+A from off -> Anime', chain, ANIME)
	H.key('Shift+A')
	H.expect('Shift+A again -> off', chain, OFF)
	H.key('Shift+Y')
	H.expect('Shift+Y from off -> Movie', chain, MOVIE)
	H.key('Shift+A')
	H.expect('Shift+A while Movie -> Anime (replaced, not stacked)', chain, ANIME)
	H.key('Shift+Y')
	H.expect('Shift+Y while Anime -> Movie', chain, MOVIE)
	H.key('Shift+Y')
	H.expect('Shift+Y again -> off', chain, OFF)

	-- ---- Movie sharpness menu ----
	send('set-upscale', '3')
	send('set-movie-sharpness', '0.5')
	H.expect('sharpness Low -> curve_height 0.500', curve_height, '0.500')
	H.expect('... sharpener still in the chain', chain, MOVIE)
	send('set-movie-sharpness', '1.5')
	H.expect('sharpness High -> curve_height 1.500', curve_height, '1.500')
	send('set-movie-sharpness', '0')
	H.expect('sharpness Off drops the sharpener from the chain', chain, MOVIE_NO_SHARPEN)
	send('set-movie-sharpness', 'auto')
	H.expect('sharpness Auto puts it back', chain, MOVIE)
	H.expect('... at 1.000', curve_height, '1.000')
	send('set-movie-sharpness', 'banana')
	send('set-upscale', '9')
	H.sleep(1)
	H.eq('an invalid sharpness or mode is ignored', chain(), MOVIE)
	H.eq('... and the strength is unchanged', curve_height(), '1.000')

	-- every loaded path exists on disk
	local missing = {}
	for _, p in ipairs(mp.get_property_native('glsl-shaders') or {}) do
		local info = utils.file_info(p)
		if not (info and info.is_file) then
			missing[#missing + 1] = p
		end
	end
	H.check('every loaded shader file exists', #missing == 0, table.concat(missing, ', '))

	send('set-upscale', '1')
	H.expect('set-upscale 1 (Auto) on a local file -> off', chain, OFF)

	-- ---- FastStream content (a #fs-content= marker in the path) ----
	H.load(H.media_path('fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'))
	H.expect('Auto + #fs-content=anime -> Anime, no clicks', chain, ANIME)
	H.load(H.media_path('fs-movie/film#fs-content=movie&fs-id=0f0f0f0f0f0f0f0f.mkv'))
	H.expect('Auto + #fs-content=movie -> Movie', chain, MOVIE)
	H.load(H.media_path('plain/clip.mkv'))
	H.expect('Auto + local file afterwards -> off again', chain, OFF)

	-- Only the host's own fragment item counts (FastStream #155): "fs-content=anime" in the
	-- stream URL's query or in a fragment item of its own picked Anime for a movie.
	H.load(
		H.media_path('fs-forged/ep&x=fs-content=anime#xfs-content=anime&fs-content=movie&fs-id=0f0f0f0f0f0f0f0f.mkv')
	)
	H.expect("Auto + forged anime markers before the host's movie tag -> Movie", chain, MOVIE)
	H.load(H.media_path('fs-forged-query/ep&x=fs-content=anime.mkv'))
	H.expect('Auto + a marker in the query only (no host tag) -> off', chain, OFF)

	H.load(H.media_path('fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'))
	binding('cycle-upscale')
	H.expect('FastStream cycle: Auto -> Anime', chain, ANIME)
	binding('cycle-upscale')
	H.expect('FastStream cycle: Anime -> Movie', chain, MOVIE)
	binding('cycle-upscale')
	H.expect('FastStream cycle: Movie -> Off', chain, OFF)
	binding('cycle-upscale')
	H.expect('FastStream cycle: Off -> Auto (not skipped here) = Anime', chain, ANIME)
	H.key('Shift+A')
	H.expect('Shift+A while Auto picked Anime counts as on -> off', chain, OFF)

	-- A named choice is sticky across files.
	send('set-upscale', '3')
	H.load(H.media_path('plain/clip.mkv'))
	H.expect('Movie chosen on one file stays on for the next file', chain, MOVIE)
end)
