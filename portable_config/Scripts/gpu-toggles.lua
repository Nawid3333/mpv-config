-- gpu-toggles.lua
-- Shader upscaling. Shift+A lives in input.conf; it sends a script message to
-- this script so the state and OSD feedback live in one place. The uosc
-- "upscale" toolbar button and the Video > Upscale menu reuse the same script
-- messages, so there is one source of truth for key, menu, and toolbar.
--
-- Upscale cycle: off -> Auto -> Anime -> Movie -> off ... Auto picks Anime or
-- Movie by content type (or nothing, for non-FastStream files - see
-- is_faststream_content()); Anime and Movie let you pick a chain yourself.

local mp = require('mp')
local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')

-- script-opts/gpu_toggles.conf. movie_sharpness is the adaptive-sharpen
-- strength the Movie presets start with: `auto` (by display scale, see
-- effective_sharpness()) or a fixed value (0 = no sharpening). The Movie
-- sharpness menu's choice is remembered in ~~state/movie-sharpness.json and
-- wins over the conf's from then on; the shader warm-ups, which step through
-- the levels, run with remember=no and so neither read nor write it.
--
-- quality: which chain of a preset runs - `auto` (measured on this PC, see
-- the "Upscaling quality" section below), `high` (the full chains) or `fast`
-- (Anime4K's own low-end set; Movie without FSRCNNX). Like the sharpness, the
-- menu's choice is remembered (~~state/upscale.json) and wins over the conf's;
-- so are the screen override and the measurements.
local opts = {
	movie_sharpness = 'auto',
	quality = 'auto',
	remember = true,
}
options.read_options(opts, 'gpu_toggles')

local SHARPNESS_FILE = mp.command_native({ 'expand-path', '~~state/' }) .. '/movie-sharpness.json'
local UPSCALE_FILE = mp.command_native({ 'expand-path', '~~state/' }) .. '/upscale.json'

local SHADER_DIR = mp.command_native({ 'expand-path', '~~/shaders' })

-- Which preset family applies to the current file. Anime presets on anime,
-- movie presets on everything else.
--
-- Sole signal: an explicit #fs-content=anime marker the FastStream browser
-- extension's mpv integration appends to the stream URL (from the MPV
-- Allowlist's per-site @anime tag, or the player's manual per-video toggle -
-- see faststream-mpv-host.mjs's withContentTypeFragment). A URL fragment: it
-- survives into mpv's `path` property unchanged and is never sent to the CDN.
-- Match literally (plain find, string compare) - an unescaped "%" here would
-- silently invoke a Lua pattern class instead of a literal match.
--
-- The marker is the LAST whole "fs-content=" item of the URL fragment
-- (everything after the first '#', items separated by '&'), as
-- stream-resume.lua reads fs-id and source-info.lua fs-page. The native host
-- drops fs-* items a stream URL already carries and appends its own last, so
-- the last item wins. Matching whole items also avoids partial hits like a
-- page's own query ("?x=fs-content=anime") or a fragment item
-- ("#xfs-content=anime"). The value is read up to its first non-letter (a
-- following file name can end in ".mkv").
---@param path string|nil
---@return string|nil
local function fs_content(path)
	local hash = path and path:find('#', 1, true)
	if not path or not hash then
		return nil
	end
	local content
	for item in (path:sub(hash + 1) .. '&'):gmatch('([^&]*)&') do
		if item:sub(1, 11) == 'fs-content=' then
			content = item:sub(12):match('^(%a*)')
		end
	end
	return content
end

local function is_anime_content()
	return fs_content(mp.get_property('path', '')) == 'anime'
end

-- Whether the current file came from FastStream at all (any #fs-content=
-- marker - anime or movie, both are sent, see the comment above) as opposed
-- to a local file or any other source, which carries no such marker.
--
-- Auto upscale (mode 1, see UPSCALE_MODE_COUNT below) is gated on this: Auto
-- was designed for FastStream streams, so it must not fire for anything else.
--
-- Consequence: a local file gets NO shaders unless the user picks Anime or
-- Movie - always their own choice. The button reads "Off" for such a file
-- (never "Auto"), the menu hides the Auto entry, and the cycle (toolbar
-- button, Video > Upscale > Cycle) skips Auto (Off -> Anime -> Movie -> Off);
-- Shift+A / Shift+Y only switch their own preset on and off. Internally the mode stays "Auto" so a
-- FastStream stream still gets its preset automatically.
local function is_faststream_content()
	return fs_content(mp.get_property('path', '')) ~= nil
end

-- ---- Upscale (2 user-facing presets: Anime / Movie) -----------------------
-- Anime: Anime4K C+A, unconditional - chosen by eye over ArtCNN and over
-- CuNNy-4x32-DS; do not swap in a "faithful" 2x CNN again. Its own
-- AutoDownscalePre stages adapt it to the real target ratio.
--
-- Movie: the chain is picked by the real scale to the display, FSRCNNX only
-- from 2x (MOVIE_FSRCNNX_MIN_SCALE, crossover measured on the real display
-- scale, not approximated by input height). Below 2x a 2x CNN followed by a
-- downscale loses 1-2 dB against plain scaling (it overshoots, then the
-- downscale throws the gain away), while SSimSuperRes - which targets the
-- real output size directly - is best or tied on every metric; from 2x up the
-- CNN's fixed 2x lines up with the target and FSRCNNX wins (+2 dB at 2x).
-- ArtCNN never wins on clean material. Other findings that stand:
--   * FSR (EASU/RCAS) is not used: it measures worse than plain
--     ewa_lanczossharp, and it cannot stack with FSRCNNX (once FSRCNNX has
--     upscaled the frame, FSR's own `WHEN OUTPUT > input` gate is false).
--   * The downscale after a 2x CNN matters: mpv's default `hermite` is soft,
--     so the Movie presets set dscale=ewa_lanczossharp while active.
--   * No vf-based upscalers (e.g. AI restoration via VapourSynth/ONNX): a
--     frame-by-frame network has no temporal consistency (fine texture is
--     re-invented every frame, so it can shimmer as detail changes), it needs
--     the GPU in bursts alongside the renderer (a second D3D12 context), and
--     it cannot follow the 2x-16x speed keys. Everything in this file is
--     spatial-only GLSL inside the render pipeline, which is why it stays
--     artifact-free. Do not re-add a vf-based upscaler.
--
-- SHARPENING: the chains above are chosen for fidelity (closest to the clean
-- master), and the faithful gain at 1.33-1.5x is a few tenths of a dB - real,
-- but not something anyone sees from the sofa. What reads as "sharper" is
-- edge contrast at the size the picture is shown, which fidelity metrics
-- penalize. So both Movie chains end with adaptive-sharpen (bacondither,
-- igv's mpv port) on the OUTPUT hook, i.e. at display resolution after all
-- scaling: edge-adaptive, with built-in anti-ringing limits (the overshoot is
-- soft-clipped against the local min/max), and it leaves flat low-contrast
-- areas alone, which is where compression noise lives. Strength is its
-- curve_height PARAM (upstream default 1.0, "0.3-2.0 reasonable"), set via
-- glsl-shader-opts, so switching levels needs no shader recompile. It is left
-- out when the video is not enlarged (e.g. a 4K file on the 1440p display) -
-- sharpening a downscale only adds aliasing. Other sharpeners do not qualify:
-- FSR RCAS and CAS.glsl/NVSharpen.glsl are gated to run only when there is NO
-- scaling (or, for the scaling variants, only as the scaler itself, so they
-- cannot follow FSRCNNX); OUTPUT-hooked adaptive-sharpen runs after whatever
-- scaler ran; mpv's own --sharpen is vo=gpu only. Rejected:
-- nlmeans_sharpen_denoise before the chain - on real x264 encodes it smeared
-- detail (waxy crops).
--
-- CHROMA: every chain above leaves colour to mpv's generic cscale, but nearly
-- every movie file is 4:2:0 - colour is stored at half the width and height -
-- so for a 720p source on the 2560x1440 display the colour planes (640x360)
-- are enlarged 4x, twice the luma ratio; for a 540p source, 5.3x. That is
-- where soft, bleeding colour edges (red/blue objects, coloured text, skin
-- against sky) come from, and no luma shader touches it. Both Movie chains
-- start with CfL_Prediction (Artoriuz, "chroma from luma", MIT; pinned
-- upstream commit in install-shaders.ps1): it predicts each colour sample
-- from the full-res luma by local linear regression (the technique AV1/VVC
-- use), blended with a normal resampler where luma and chroma do not
-- correlate, then smoothed bilaterally. It beats KrigBilateral and every
-- plain scaler in Artoriuz's own chroma benchmarks. It hooks CHROMA and binds
-- LUMA, so it sizes the colour planes to whatever luma is at that point
-- (FSRCNNX's 2x output when that runs - the same pairing as the classic
-- FSRCNNX + KrigBilateral). Cheap: it works at chroma resolution. No effect
-- on 4:4:4 or RGB sources (its WHEN gate is CHROMA.w < LUMA.w).
local UPSCALE_ANIME = {
	id = 'anime-high',
	name = 'Anime4K C+A (HQ) [anime]',
	shaders = {
		'Anime4K_Clamp_Highlights.glsl',
		'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
		'Anime4K_AutoDownscalePre_x2.glsl',
		'Anime4K_AutoDownscalePre_x4.glsl',
		'Anime4K_Restore_CNN_M.glsl',
		'Anime4K_Upscale_CNN_x2_M.glsl',
	},
}
-- Quality Fast: the same Mode C+A out of Anime4K's own template for low-end
-- GPUs (the HQ variant above is its high-end template): M instead of VL for
-- the first upscale, S instead of M after it. Same look, about half the work.
local UPSCALE_ANIME_FAST = {
	id = 'anime-fast',
	name = 'Anime4K C+A (Fast) [anime]',
	shaders = {
		'Anime4K_Clamp_Highlights.glsl',
		'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
		'Anime4K_AutoDownscalePre_x2.glsl',
		'Anime4K_AutoDownscalePre_x4.glsl',
		'Anime4K_Restore_CNN_S.glsl',
		'Anime4K_Upscale_CNN_x2_S.glsl',
	},
}
-- `dscale` is applied while a preset is active and restored to the
-- mpv.conf/default value otherwise (see apply_shader_preset()).
-- `sharpen` appends SHARPEN_SHADER at the current movie_sharpness (see
-- preset_shaders()).
local UPSCALE_MOVIE_SSSR = {
	id = 'movie-sssr',
	name = 'SSimSuperRes + CfL chroma [movie, <2x]',
	shaders = { 'SSimSuperRes.glsl', 'CfL_Prediction.glsl' },
	dscale = 'ewa_lanczossharp',
	sharpen = true,
}
local UPSCALE_MOVIE_FSRCNNX = {
	id = 'movie-fsrcnnx',
	name = 'FSRCNNX + SSimSuperRes + CfL chroma [movie, >=2x]',
	shaders = { 'FSRCNNX_x2_16-0-4-1.glsl', 'SSimSuperRes.glsl', 'CfL_Prediction.glsl' },
	dscale = 'ewa_lanczossharp',
	sharpen = true,
}
local MOVIE_FSRCNNX_MIN_SCALE = 2.0

local function is_anime_preset(preset)
	return preset == UPSCALE_ANIME or preset == UPSCALE_ANIME_FAST
end

local function is_movie_preset(preset)
	return preset == UPSCALE_MOVIE_SSSR or preset == UPSCALE_MOVIE_FSRCNNX
end

-- 'Anime4K C+A (HQ) [anime]' -> 'Anime4K C+A (HQ)'
local function short_name(preset)
	return (preset.name:gsub('%s*%[.*%]$', ''))
end

-- Fixed sharpening strength levels offered in the menu next to Auto
-- (adaptive-sharpen's curve_height). 0 drops the shader entirely, which is
-- also the quickest A/B against the unsharpened chain.
local SHARPEN_SHADER = 'adaptive-sharpen.glsl'
local SHARPEN_OPT = 'adaptive-sharpen/curve_height'
local SHARPEN_LEVELS = {
	{ name = 'Off', value = 0, note = 'softest, closest to the source' },
	{ name = 'Low', value = 0.5 },
	{ name = 'Medium', value = 1.0 },
	{ name = 'High', value = 1.5, note = 'crispest, may look harsh' },
}
local SHARPEN_MAX = 4.0 -- the PARAM's own MAXIMUM in adaptive-sharpen.glsl

local function clamp_sharpness(v)
	v = tonumber(v)
	if not v or v ~= v then
		return nil
	end
	return math.max(0, math.min(SHARPEN_MAX, v))
end

local SHARPEN_AUTO = 'auto'

-- 'auto' or a fixed strength; nil for anything else.
local function parse_sharpness(v)
	if type(v) == 'string' and v:lower() == SHARPEN_AUTO then
		return SHARPEN_AUTO
	end
	return clamp_sharpness(v)
end

-- The remembered Movie sharpness, or nil (none yet, unreadable, or remember=no).
local function load_sharpness()
	if not opts.remember then
		return nil
	end
	local f = io.open(SHARPNESS_FILE, 'r')
	if not f then
		return nil
	end
	local data = utils.parse_json(f:read('*a'))
	f:close()
	if type(data) ~= 'table' then
		return nil
	end
	return parse_sharpness(data.sharpness)
end

-- Through a temp file of this process's own, so a crash cannot leave it empty.
local function save_sharpness(v)
	if not opts.remember then
		return
	end
	local json = utils.format_json({ sharpness = v })
	local tmp = SHARPNESS_FILE .. '.' .. utils.getpid() .. '.tmp'
	local f = json and io.open(tmp, 'w')
	if not f then
		msg.warn('cannot write ' .. tmp)
		return
	end
	f:write(json)
	f:close()
	os.remove(SHARPNESS_FILE)
	if not os.rename(tmp, SHARPNESS_FILE) then
		msg.warn('cannot replace ' .. SHARPNESS_FILE)
	end
end

local movie_sharpness = load_sharpness() or parse_sharpness(opts.movie_sharpness) or SHARPEN_AUTO -- the SETTING

local function sharpness_label(v)
	for _, level in ipairs(SHARPEN_LEVELS) do
		if math.abs(level.value - v) < 1e-6 then
			return level.name
		end
	end
	return string.format('%.2f', v)
end

-- Starts at 1 (Auto), not 0: on FastStream content that is the right preset
-- with no clicks; on a local file it resolves to no shaders (see
-- is_faststream_content()).
local upscale_mode = 1 -- 0=off, 1=Auto, 2=Anime, 3=Movie, see preset_for_mode()

-- ---- Upscaling quality and the screen -------------------------------------
-- Settings stored per PC in ~~state/upscale.json (the shader warm-ups, which
-- run with remember=no, neither read nor write it):
--   quality  'auto' | 'high' | 'fast' (see opts)
--   screen   'auto' (the monitor mpv is on, display-width/height) or 'WxH': the
--            screen size the choices below are made for - the Movie chain by
--            scale, Auto sharpness, and which measurements count. Anime4K's own
--            stages follow the real output size whatever this says (their WHEN
--            lines read it on the GPU).
--   costs    what each chain cost per frame on this GPU in ms, measured in the
--            real player (vo-passes, the render passes' own GPU timers), keyed
--            by chain, screen and source size: 'anime-high|2560x1440|1080p'.
local QUALITIES = { auto = true, high = true, fast = true }
local SCREENS = { '1920x1080', '2560x1440', '3440x1440', '3840x2160' }

local function load_upscale_state()
	local state = { costs = {} }
	if not opts.remember then
		return state
	end
	local f = io.open(UPSCALE_FILE, 'r')
	if not f then
		return state
	end
	local data = utils.parse_json(f:read('*a'))
	f:close()
	if type(data) ~= 'table' then
		return state
	end
	if QUALITIES[data.quality] then
		state.quality = data.quality
	end
	if type(data.screen) == 'string' and (data.screen == 'auto' or data.screen:match('^%d+x%d+$')) then
		state.screen = data.screen
	end
	if data.anime_lines == 'crisp' or data.anime_lines == 'drawn' then
		state.anime_lines = data.anime_lines
	end
	if type(data.costs) == 'table' then
		for k, v in pairs(data.costs) do
			if type(k) == 'string' and type(v) == 'number' and v > 0 then
				state.costs[k] = v
			end
		end
	end
	return state
end

local saved = load_upscale_state()
-- The quality chosen in the menu, or nil. Only that one is saved, so a later
-- quality= change in the conf still takes effect.
local chosen_quality = saved.quality
local quality = chosen_quality or (QUALITIES[opts.quality] and opts.quality) or 'auto'
local screen = saved.screen or 'auto'
local costs = saved.costs
-- Anime lines: 'crisp' runs Anime4K's Restore step, which redraws lines
-- crisper and thinner - right for lines a source blurred, too much for line
-- art that is clean or soft by design. 'drawn' leaves it out (Anime4K's Mode
-- C: the denoising upscale and the upscale only). One setting for all anime,
-- kept in upscale.json.
local anime_lines = saved.anime_lines or 'crisp'

-- Through a temp file of this process's own, as save_sharpness().
local function save_upscale_state()
	if not opts.remember then
		return
	end
	local json =
		utils.format_json({ quality = chosen_quality, screen = screen, costs = costs, anime_lines = anime_lines })
	local tmp = UPSCALE_FILE .. '.' .. utils.getpid() .. '.tmp'
	local f = json and io.open(tmp, 'w')
	if not f then
		msg.warn('cannot write ' .. tmp)
		return
	end
	f:write(json)
	f:close()
	os.remove(UPSCALE_FILE)
	if not os.rename(tmp, UPSCALE_FILE) then
		msg.warn('cannot replace ' .. UPSCALE_FILE)
	end
end

-- The screen override as two numbers, or nil (auto).
local function screen_override()
	local w, h = screen:match('^(%d+)x(%d+)$')
	if w then
		return tonumber(w), tonumber(h)
	end
	return nil
end

-- What the display reads, the source size, and the scale between them (fullscreen
-- fit). `scale` and the sizes are nil while unknown.
local function read_display()
	local d = {}
	local vw, vh = mp.get_property_number('width'), mp.get_property_number('height')
	-- width/height are before rotation: a 1080x1920 phone video shown upright on
	-- 2560x1440 counted as 1.33x (Movie + sharpening) where it is a downscale.
	local rotate = mp.get_property_number('video-params/rotate')
		or mp.get_property_number('current-tracks/video/demux-rotation')
		or 0
	if vw and vh and rotate % 180 == 90 then
		vw, vh = vh, vw
	end
	local real_w = mp.get_property_number('display-width') or mp.get_property_number('osd-width')
	local real_h = mp.get_property_number('display-height') or mp.get_property_number('osd-height')
	if real_w and real_h and real_w > 0 and real_h > 0 then
		d.detected_w, d.detected_h = real_w, real_h
	end
	local dw, dh = screen_override()
	if not dw then
		dw, dh = d.detected_w, d.detected_h
	end
	d.dw, d.dh = dw, dh
	if vw and vh and vw > 0 and vh > 0 then
		d.vw, d.vh = vw, vh
	end
	if d.vw and d.dw then
		d.scale = math.min(d.dw / d.vw, d.dh / d.vh)
	end
	return d
end

-- The scale is read at most ONCE per action, and only if the action needs it:
-- every entry point (key, menu message, file-loaded - see entry() at the
-- bottom) calls forget_display_scale() first, and the first display_scale()
-- call of that action reads it. display-width/height are answered by the
-- video thread, so each read waits for it - the cache keeps one switch down
-- to one read. Off reads nothing; Anime only the sizes quality Auto's cost key
-- needs (with quality High or Fast, nothing).
local current_display = nil -- read_display() of this action, nil = not read yet

local function forget_display_scale()
	current_display = nil
end

local function display()
	if not current_display then
		current_display = read_display()
	end
	return current_display
end

local function display_scale()
	return display().scale
end

-- The strength actually applied. Auto = display scale - 1, clamped to
-- 0.5..1.5: measured across 1.33x-3x, this tracks the clean master's own edge
-- sharpness at every scale, while no single fixed level fits every scale.
local AUTO_SHARPEN_MIN, AUTO_SHARPEN_MAX = 0.5, 1.5
local function effective_sharpness()
	if movie_sharpness ~= SHARPEN_AUTO then
		return movie_sharpness
	end
	local s = display_scale()
	if not s then
		return 1.0
	end
	return math.max(AUTO_SHARPEN_MIN, math.min(AUTO_SHARPEN_MAX, s - 1))
end

-- Menu/OSD name of the current setting, e.g. "Auto (1.00)" or "Low".
local function setting_label()
	if movie_sharpness == SHARPEN_AUTO then
		return string.format('Auto (%.2f)', effective_sharpness())
	end
	return sharpness_label(movie_sharpness)
end

-- ---- Upscaling quality Auto -------------------------------------------------
-- A chain that is fine on a fast GPU can be many times too slow on a weak
-- one, so Auto does not guess from the GPU's name: the first time a high
-- chain (Anime4K HQ, or Movie's FSRCNNX at 2x and more) runs for a screen and
-- source size, the render passes' own GPU timers (vo-passes) are read once it
-- has played MEASURE_AFTER seconds. Over BUDGET_SHARE of a frame's time (half
-- a frame; at 1x, the video's own fps) and Auto switches to the fast chain,
-- says so in a banner with the number, and takes the fast one for that size
-- from then on. Every chain stays selectable: the Settings menu and the
-- upscale menu list High and Fast with what each cost here and mark Auto's
-- pick.
local BUDGET_SHARE = 0.5
local MEASURE_AFTER = 3

-- The source's size class, by its pixel count as a 16:9 height (1920x800 is a
-- 1080p-class picture, not a 720p one).
local function source_class(d)
	if not d.vw then
		return nil
	end
	local h = math.sqrt(d.vw * d.vh * 9 / 16)
	for _, c in ipairs({ { 400, '360p' }, { 600, '480p' }, { 800, '720p' }, { 1200, '1080p' }, { 1600, '1440p' } }) do
		if h <= c[1] then
			return c[2]
		end
	end
	return '2160p'
end

local function cost_key(id, d)
	d = d or display()
	local class = source_class(d)
	if not (d.dw and class) then
		return nil
	end
	return string.format('%s|%dx%d|%s', id, d.dw, d.dh, class)
end

local function cost_of(preset, d)
	local key = cost_key(preset.id, d)
	return key and costs[key]
end

local function video_fps()
	for _, prop in ipairs({ 'container-fps', 'estimated-vf-fps' }) do
		local fps = mp.get_property_number(prop)
		if fps and fps > 1 and fps <= 300 then
			return fps
		end
	end
	return 30
end

local function frame_budget_ms()
	return 1000 / video_fps() * BUDGET_SHARE
end

-- Auto's choice: the high chain unless it was measured too slow here, then
-- the fast one unless that was too, then none - upscaling off for that screen
-- and source size. nil = off.
local function auto_pick(high, fast)
	local budget = frame_budget_ms()
	for _, preset in ipairs({ high, fast }) do
		local ms = cost_of(preset)
		if not (ms and ms > budget) then
			return preset
		end
	end
	return nil
end

local function pick(high, fast)
	if quality == 'fast' then
		return fast
	elseif quality == 'high' then
		return high
	end
	return auto_pick(high, fast)
end

local function current_anime_preset()
	return pick(UPSCALE_ANIME, UPSCALE_ANIME_FAST)
end

-- Picks the Movie chain by the real scale to the display: at 2x and more
-- FSRCNNX + SSimSuperRes, unless the quality takes the fast one; below 2x
-- SSimSuperRes is the only chain (Auto: off when even that does not fit).
local function current_movie_preset()
	local s = display_scale()
	if s and s >= MOVIE_FSRCNNX_MIN_SCALE then
		return pick(UPSCALE_MOVIE_FSRCNNX, UPSCALE_MOVIE_SSSR)
	end
	return pick(UPSCALE_MOVIE_SSSR, UPSCALE_MOVIE_SSSR)
end

-- Whether a `sharpen` preset gets adaptive-sharpen right now: strength above
-- 0 and the video really enlarged (unknown scale counts as enlarged - the
-- common case, and the next file-loaded re-evaluates anyway).
local function sharpen_active(preset)
	if not (preset and preset.sharpen) or effective_sharpness() <= 0 then
		return false
	end
	local s = display_scale()
	return s == nil or s > 1
end

-- The shader file list a preset runs right now: its own chain plus, while
-- sharpen_active(), the sharpener LAST (OUTPUT hook, after all scaling).
local function preset_shaders(preset)
	local list = {}
	local drawn = anime_lines == 'drawn' and is_anime_preset(preset)
	for _, name in ipairs(preset.shaders) do
		-- Anime lines "as drawn": no Restore step (see anime_lines).
		if not (drawn and name:match('^Anime4K_Restore_')) then
			list[#list + 1] = name
		end
	end
	if sharpen_active(preset) then
		list[#list + 1] = SHARPEN_SHADER
	end
	return list
end

-- Identifies what is actually loaded, so apply_upscale() can skip a reload
-- only when nothing would change - the preset table alone is not enough once
-- the list also depends on the scale and the sharpness level.
local function chain_key(preset)
	if not preset then
		return 'off'
	end
	local key = table.concat(preset_shaders(preset), ';')
	if sharpen_active(preset) then
		key = key .. '|' .. string.format('%.3f', effective_sharpness())
	end
	return key
end

-- Human-readable suffix for the button's tooltip: the sharpening state of a preset.
local function sharpen_suffix(preset)
	if not (preset and preset.sharpen) then
		return ''
	end
	if sharpen_active(preset) then
		return ' + sharpen ' .. setting_label()
	end
	if effective_sharpness() <= 0 then
		return ' (sharpen off)'
	end
	return ' (sharpen off: not enlarged)'
end

-- Sets adaptive-sharpen's strength without touching any other shader option.
local function set_sharpen_opt(value)
	local shader_opts = mp.get_property_native('glsl-shader-opts') or {}
	local want = string.format('%.3f', value)
	if shader_opts[SHARPEN_OPT] == want then
		return true -- unchanged: skip the option write (a round trip to the video thread)
	end
	shader_opts[SHARPEN_OPT] = want
	local ok, err = mp.set_property_native('glsl-shader-opts', shader_opts)
	if not ok then
		msg.warn('could not set glsl-shader-opts: ' .. tostring(err))
	end
	return ok
end

-- Picks the preset for the current file, for Auto mode only: nil (off)
-- unless the file is FastStream content (see is_faststream_content() above),
-- then content type (anime vs movie).
local function current_upscale_preset()
	if not is_faststream_content() then
		return nil
	end
	-- not `a and b or c`: with Anime off as too slow here (nil), that ran Movie on
	-- an anime stream
	if is_anime_content() then
		return current_anime_preset()
	end
	return current_movie_preset()
end

-- Upscale button modes: 0=off, 1=Auto (current_upscale_preset(), re-evaluated
-- per file), 2=Anime, 3=Movie (skips the anime/movie content-type detection).
local UPSCALE_MODE_COUNT = 4

-- Resolves a button mode to the preset it should apply right now (nil for
-- off). Mode 1 (Auto) re-evaluates on every call rather than caching, so it
-- follows a new file's content type - see apply_upscale()/file-loaded.
local function preset_for_mode(mode)
	if mode == 0 then
		return nil
	elseif mode == 1 then
		return current_upscale_preset()
	elseif mode == 2 then
		return current_anime_preset()
	elseif mode == 3 then
		return current_movie_preset()
	end
end

-- Resolve preset names to full paths and drop missing files, so a preset
-- with a deleted shader does not poison the whole chain (mpv aborts the
-- whole list if one file fails to load).
local function resolve(shaders)
	local resolved, missing = {}, {}
	for _, name in ipairs(shaders) do
		local path = utils.join_path(SHADER_DIR, name)
		local info = utils.file_info(path)
		if info and info.is_file then
			resolved[#resolved + 1] = path
		else
			missing[#missing + 1] = name
		end
	end
	return resolved, missing
end

-- dscale as configured at startup (mpv.conf or mpv's default): presets may
-- override it while active (see UPSCALE_MOVIE_SSSR.dscale); everything else
-- gets this back, so the Anime chain and "off" keep the configured scaler.
local BASE_DSCALE = mp.get_property('dscale')

-- A banner top right (Scripts/notify.lua draws every message; the same id
-- replaces the last one, so fast switching shows one banner). Title: what runs;
-- grey line: the chain, e.g. "Upscale: Movie" over
-- "SSimSuperRes + CfL chroma · sharpen Auto (1.00)".
local function notify(title, detail)
	mp.commandv('script-message-to', 'notify', 'show', 'shaders', title, detail or '')
end

local function announce_preset(preset, suffix)
	if not preset then
		notify('Upscale: off')
		return
	end
	local detail = short_name(preset)
	if preset.sharpen then
		if sharpen_active(preset) then
			detail = detail .. ' · sharpen ' .. setting_label()
		elseif effective_sharpness() <= 0 then
			detail = detail .. ' · sharpen off'
		else
			detail = detail .. ' · sharpen off (not enlarged)'
		end
	end
	notify('Upscale: ' .. (is_anime_preset(preset) and 'Anime' or 'Movie') .. (suffix or ''), detail)
end

local function apply_shader_preset(preset, suffix)
	local want_dscale = (preset and preset.dscale) or BASE_DSCALE
	if want_dscale and mp.get_property('dscale') ~= want_dscale then
		mp.set_property('dscale', want_dscale)
	end
	if not preset then
		mp.commandv('no-osd', 'change-list', 'glsl-shaders', 'clr', '')
		announce_preset(nil)
		return true
	end

	-- Strength first, so the sharpener never runs even one frame at a stale
	-- value when the list below loads it.
	if sharpen_active(preset) then
		set_sharpen_opt(effective_sharpness())
	end

	local resolved, missing = resolve(preset_shaders(preset))
	if #missing > 0 then
		msg.warn('preset "' .. preset.name .. '" missing files: ' .. table.concat(missing, ', '))
	end
	if #resolved == 0 then
		-- Nothing of this preset is on disk. Clear the list rather than
		-- leaving the PREVIOUS preset's chain silently running while the OSD
		-- says otherwise, and report the failure so apply_upscale() does not
		-- record a preset that never got applied. The downscaler goes back with
		-- it: the preset's dscale was set above, for shaders that are not there.
		mp.commandv('no-osd', 'change-list', 'glsl-shaders', 'clr', '')
		if BASE_DSCALE and mp.get_property('dscale') ~= BASE_DSCALE then
			mp.set_property('dscale', BASE_DSCALE)
		end
		notify('Upscale: off', 'files of this preset are missing - see the log')
		return false
	end

	-- Replace the whole list in one atomic command (change-list ... set).
	mp.commandv('no-osd', 'change-list', 'glsl-shaders', 'set', table.concat(resolved, ';'))
	announce_preset(preset, suffix)
	return true
end

-- ---- uosc toolbar button ----------------------------------------------------
-- Managed button (uosc.conf controls= has "button:upscale") whose look/state
-- is pushed via script-message-to uosc set-button, same pattern as
-- scripts/speed-button.lua's "speed" button.
-- Last JSON pushed per button. uosc's `set-button` handler calls
-- request_render() unconditionally (see uosc/lib/buttons.lua), so re-sending
-- an unchanged button forces a full UI repaint for nothing.
local last_button_json = {}

local function set_uosc_button(name, data)
	local json, err = utils.format_json(data)
	if not json then
		msg.error('Failed to format ' .. name .. ' button JSON: ' .. tostring(err))
		return
	end
	if last_button_json[name] == json then
		return -- nothing changed; skip the push and uosc's repaint
	end
	last_button_json[name] = json
	mp.commandv('script-message-to', 'uosc', 'set-button', name, json)
end

local upscale_active_preset = nil -- nil | UPSCALE_ANIME(_FAST) | UPSCALE_MOVIE_SSSR | UPSCALE_MOVIE_FSRCNNX
local upscale_active_key = 'off' -- chain_key() of what is loaded

-- The preset family on screen ('anime' | 'movie' | 'off') in
-- user-data/gpu-toggles/preset: the tests read which chain ran from it, not
-- from the shader file names.
local function publish_family(preset)
	local family = 'off'
	if is_anime_preset(preset) then
		family = 'anime'
	elseif preset then
		family = 'movie'
	end
	mp.set_property_native('user-data/gpu-toggles/preset', family)
end
publish_family(nil)

-- Short badge per preset, keyed by their .name. Kept to 4 chars - uosc draws a
-- button's badge sized to the button's own fixed icon box (see
-- uosc/elements/Button.lua's render(); Controls.lua hardcodes ratio=1 for
-- `button:` elements, so that box never grows for a longer badge) - a longer
-- badge just draws past the box's left edge, overlapping whatever button sits
-- next to it. The full preset name is still in the tooltip on hover.
local UPSCALE_BADGES = {
	[UPSCALE_ANIME.name] = 'Anim',
	[UPSCALE_ANIME_FAST.name] = 'Anim',
	[UPSCALE_MOVIE_SSSR.name] = 'Movi',
	[UPSCALE_MOVIE_FSRCNNX.name] = 'Movi',
}

local function update_upscale_button()
	local badge, tooltip
	if upscale_mode == 0 then
		badge = 'Off'
		tooltip = 'Upscale: off'
	elseif upscale_mode == 1 then
		-- Auto only does something for FastStream content (see
		-- is_faststream_content()); everywhere else it resolves to no shaders,
		-- and the button says so honestly: "Off", not "Auto". The internal
		-- mode stays 1 so a FastStream stream loaded next still gets its
		-- preset automatically, with the badge showing it.
		local preset = mp.get_property_number('height') and current_upscale_preset() or nil
		if preset then
			badge = UPSCALE_BADGES[preset.name] or '?'
			tooltip = 'Upscale: ' .. preset.name .. sharpen_suffix(preset) .. ' (Auto, for this file)'
		elseif mp.get_property_number('height') and is_faststream_content() then
			-- A FastStream stream Auto measured too slow for this GPU; the text
			-- keeps the promise of an automatic start.
			badge = 'Off'
			tooltip = 'Upscale: off here - too slow on this GPU (Auto; Settings > Upscaling quality)'
		else
			badge = 'Off'
			tooltip = 'Upscale: off (FastStream streams start automatically)'
		end
	else
		local preset = preset_for_mode(upscale_mode)
		if preset then
			badge = UPSCALE_BADGES[preset.name] or '?'
			tooltip = 'Upscale: ' .. preset.name .. sharpen_suffix(preset)
		else
			-- quality Auto measured even the fast chain too slow here
			badge = 'Off'
			tooltip = 'Upscale: '
				.. (upscale_mode == 2 and 'Anime' or 'Movie')
				.. ' is off here - too slow on this GPU (Settings > Upscaling quality)'
		end
	end
	set_uosc_button('upscale', {
		icon = 'auto_awesome',
		badge = badge,
		tooltip = tooltip .. ' - click: next, right-click: menu',
		command = { 'script-message-to', 'gpu_toggles', 'cycle-upscale' },
		menu_command = { 'script-message-to', 'gpu_toggles', 'open-upscale-menu' },
	})
end

local QUALITY_NAMES = { auto = 'Auto', high = 'High', fast = 'Fast' }

local function ms_text(ms)
	return ms and string.format('%.1f ms', ms) or 'not measured yet'
end

-- What the quality items talk about: the family on screen, else the file's.
local function quality_family()
	if upscale_active_preset then
		return is_anime_preset(upscale_active_preset) and 'anime' or 'movie'
	end
	return is_anime_content() and 'anime' or 'movie'
end

-- The family's high and fast chain for this scale (Movie below 2x: one chain).
local function family_chains(family)
	if family == 'anime' then
		return UPSCALE_ANIME, UPSCALE_ANIME_FAST
	end
	local s = display_scale()
	if s and s >= MOVIE_FSRCNNX_MIN_SCALE then
		return UPSCALE_MOVIE_FSRCNNX, UPSCALE_MOVIE_SSSR
	end
	return UPSCALE_MOVIE_SSSR, UPSCALE_MOVIE_SSSR
end

-- 'High' | 'Fast' | 'Off': what quality Auto runs for that family here.
local function auto_word(high, fast)
	local preset = auto_pick(high, fast)
	if not preset then
		return 'Off'
	end
	return preset == high and 'High' or 'Fast'
end

-- "Auto (High)" etc.
local function quality_label()
	if quality ~= 'auto' then
		return QUALITY_NAMES[quality]
	end
	return 'Auto (' .. auto_word(family_chains(quality_family())) .. ')'
end

-- Why quality Auto runs nothing for the upscaling that is asked for, or nil.
local function auto_off_note()
	if quality ~= 'auto' or upscale_mode == 0 then
		return nil
	end
	local family
	if upscale_mode == 2 then
		family = 'anime'
	elseif upscale_mode == 3 then
		family = 'movie'
	elseif is_faststream_content() then
		family = is_anime_content() and 'anime' or 'movie'
	else
		return nil
	end
	local high, fast = family_chains(family)
	if auto_pick(high, fast) then
		return nil
	end
	return string.format(
		'%s took %.1f ms per frame on this GPU (%.0f fit) · Settings > Upscaling quality runs it anyway',
		short_name(fast),
		cost_of(fast) or 0,
		frame_budget_ms()
	)
end

-- uosc menu items, with keep_open: a choice shows its effect in the open menu
-- (update_menus()). The Settings menu (Scripts/settings.lua) embeds the same
-- items from user-data/gpu-toggles/quality.
-- A dimmed explaining line at the top of a submenu (not selectable).
local function note(title, separator)
	return { title = title, muted = true, selectable = false, separator = separator }
end

local function quality_items()
	local family = quality_family()
	local high, fast = family_chains(family)
	local word = auto_word(high, fast)
	local budget = frame_budget_ms()
	local function chain_hint(preset, recommended)
		local hint = short_name(preset) .. ' · ' .. ms_text(cost_of(preset))
		return recommended and (hint .. ' · recommended') or hint
	end
	return {
		note('How much GPU time the upscaling may take.'),
		note('Auto: High if it fits, else Fast, else off.'),
		note('A choice here always runs, even if it is slow.', true),
		{
			title = 'Auto (measured on this PC)',
			hint = word == 'Off' and 'Off now - too slow here' or (word .. ' now'),
			value = 'script-message-to gpu_toggles set-quality auto',
			active = quality == 'auto',
			keep_open = true,
		},
		{
			title = 'High',
			hint = chain_hint(high, word == 'High'),
			value = 'script-message-to gpu_toggles set-quality high',
			active = quality == 'high',
			keep_open = true,
		},
		{
			title = 'Fast',
			hint = chain_hint(fast, word == 'Fast'),
			value = 'script-message-to gpu_toggles set-quality fast',
			active = quality == 'fast',
			keep_open = true,
			separator = true,
		},
		{
			title = string.format('Fits: up to %.0f ms per frame', budget),
			hint = string.format('half a frame at %.3g fps', video_fps()),
			muted = true,
			selectable = false,
		},
		{
			title = 'Measure again',
			hint = 'forget what was measured on this PC',
			value = 'script-message-to gpu_toggles forget-measurements',
			keep_open = true,
		},
	}
end

local function screen_label()
	local d = display()
	if screen == 'auto' then
		return d.detected_w and string.format('Auto (%dx%d)', d.detected_w, d.detected_h) or 'Auto'
	end
	return screen
end

local function screen_items()
	local d = display()
	local detected = d.detected_w and string.format('%dx%d', d.detected_w, d.detected_h)
	local items = {
		note('The screen size the upscaling plans for: which'),
		note('Movie chain runs and how much it sharpens.'),
		note('Leave it on Auto unless mpv reads it wrong.', true),
		{
			title = 'Auto (the screen mpv is on)',
			hint = detected or 'not known yet',
			value = 'script-message-to gpu_toggles set-screen auto',
			active = screen == 'auto',
			keep_open = true,
			separator = true,
		},
	}
	local listed = false
	for _, size in ipairs(SCREENS) do
		listed = listed or size == screen
		items[#items + 1] = {
			title = size,
			hint = size == detected and 'this screen' or nil,
			value = 'script-message-to gpu_toggles set-screen ' .. size,
			active = screen == size,
			keep_open = true,
		}
	end
	if screen ~= 'auto' and not listed then
		items[#items + 1] = { title = screen, active = true, keep_open = true }
	end
	return items
end

local function sharpness_items()
	local auto = movie_sharpness == SHARPEN_AUTO
	local items = {
		note('Extra crispness for films after upscaling: it looks'),
		note('sharper, it adds no detail. More = crisper, harsher.', true),
		{
			title = 'Auto (by scale)',
			hint = string.format('%.2f now', effective_sharpness()),
			value = 'script-message-to gpu_toggles set-movie-sharpness auto',
			active = auto,
			keep_open = true,
			separator = true,
		},
	}
	for _, level in ipairs(SHARPEN_LEVELS) do
		items[#items + 1] = {
			title = level.name,
			hint = level.note or string.format('%.1f', level.value),
			value = 'script-message-to gpu_toggles set-movie-sharpness ' .. level.value,
			active = not auto and math.abs(level.value - movie_sharpness) < 1e-6,
			keep_open = true,
		}
	end
	return items
end

local function anime_lines_label()
	return anime_lines == 'drawn' and 'As drawn' or 'Crisp'
end

local function anime_lines_items()
	return {
		note('Anime upscaling redraws lines crisper and thinner.'),
		note('Too thin for one show? As drawn keeps its own lines.', true),
		{
			title = 'Crisp',
			hint = 'crisper, thinner lines',
			value = 'script-message-to gpu_toggles set-anime-lines crisp',
			active = anime_lines == 'crisp',
			keep_open = true,
		},
		{
			title = 'As drawn',
			hint = "the show's own lines",
			value = 'script-message-to gpu_toggles set-anime-lines drawn',
			active = anime_lines == 'drawn',
			keep_open = true,
		},
	}
end

local function chain_costs()
	local out = {}
	for _, preset in ipairs({ UPSCALE_ANIME, UPSCALE_ANIME_FAST, UPSCALE_MOVIE_FSRCNNX, UPSCALE_MOVIE_SSSR }) do
		out[preset.id] = cost_of(preset)
	end
	return out
end

-- user-data/gpu-toggles/quality: the settings, what Auto picks, what was
-- measured here, and the menu items (Scripts/settings.lua, the tests).
local function publish_quality()
	local d = display()
	mp.set_property_native('user-data/gpu-toggles/quality', {
		setting = quality,
		label = quality_label(),
		anime = (current_anime_preset() or { id = 'off' }).id,
		movie = (current_movie_preset() or { id = 'off' }).id,
		screen = screen,
		screen_label = screen_label(),
		detected = d.detected_w and string.format('%dx%d', d.detected_w, d.detected_h) or nil,
		used = d.dw and string.format('%dx%d', d.dw, d.dh) or nil,
		source = source_class(d),
		budget_ms = frame_budget_ms(),
		costs = chain_costs(),
		sharpness_label = setting_label(),
		quality_items = quality_items(),
		screen_items = screen_items(),
		sharpness_items = sharpness_items(),
		anime_lines_label = anime_lines_label(),
		anime_lines_items = anime_lines_items(),
	})
end

local function open_upscale_menu(update)
	-- Auto is only offered (and highlighted) for FastStream content; on any
	-- other file it is the same as Off, so "Off" is the highlighted entry then.
	local faststream = is_faststream_content()
	local items = {
		{
			title = 'Off',
			value = 'script-message-to gpu_toggles set-upscale 0',
			active = upscale_mode == 0 or (upscale_mode == 1 and not faststream),
		},
	}
	if faststream then
		items[#items + 1] = {
			title = 'Auto',
			value = 'script-message-to gpu_toggles set-upscale 1',
			active = upscale_mode == 1,
		}
	end
	items[#items + 1] =
		{ title = 'Anime', value = 'script-message-to gpu_toggles set-upscale 2', active = upscale_mode == 2 }
	items[#items + 1] =
		{ title = 'Movie', value = 'script-message-to gpu_toggles set-upscale 3', active = upscale_mode == 3 }
	items[#items].separator = true
	items[#items + 1] = { title = 'Quality', hint = quality_label(), items = quality_items() }
	items[#items + 1] = { title = 'Anime lines', hint = anime_lines_label(), items = anime_lines_items() }
	items[#items + 1] =
		{ title = 'Movie sharpness', hint = setting_label(), items = sharpness_items(), separator = true }
	-- shader-cache/main.lua: deletes mpv's own compiled shaders (never AMD's
	-- driver cache) and compiles every chain again in the background
	items[#items + 1] = {
		title = 'Rebuild shaders',
		hint = "mpv's cache only",
		value = 'script-message-to shader_cache rebuild',
	}
	local data = { type = 'upscale-menu', title = 'Upscale', items = items }
	local json, err = utils.format_json(data)
	if json then
		if update then
			-- uosc acts on it only while this menu is open
			mp.commandv('script-message-to', 'uosc', 'update-menu', json)
		else
			mp.commandv('script-message-to', 'uosc', 'open-menu', json)
		end
	else
		msg.error('Failed to format upscale menu JSON: ' .. tostring(err))
	end
end

-- ---- Upscale cycle (toolbar button, menu) -----------------------------------
local schedule_measure -- below: times the chain that was just applied

-- `announce` is true for a user-initiated change (key, menu, toolbar) and
-- false for the automatic per-file re-evaluation, which should stay quiet
-- when nothing actually changed.
local function apply_upscale(announce)
	local preset = preset_for_mode(upscale_mode)
	-- Mode 1 keeps an "(Auto)" suffix so Auto vs. a direct pick is visible on
	-- the OSD even when both resolve to the same chain; named modes 2/3 need
	-- no qualifier - the preset name is the whole message.
	local suffix = upscale_mode == 1 and ' (Auto)' or nil
	-- off because quality Auto measured even the fast chain too slow here
	local off_note = not preset and auto_off_note() or nil

	if preset == upscale_active_preset and chain_key(preset) == upscale_active_key then
		-- Same shader chain as what is already loaded - skip the recompile,
		-- but still confirm on the OSD when the user asked for this, since
		-- two different modes can resolve to the same preset (Auto on an
		-- anime file and the Anime choice are the same table) - cycling
		-- between them would otherwise look like a dead keypress.
		if announce and off_note then
			notify('Upscaling off here', off_note)
		elseif announce then
			announce_preset(preset, suffix)
		end
		update_upscale_button()
		schedule_measure()
		return
	end

	if apply_shader_preset(preset, suffix) then
		upscale_active_preset = preset
		upscale_active_key = chain_key(preset)
	else
		-- The preset could not be applied and the chain was cleared, so the
		-- live state is "no shaders", not "this preset". Recording the
		-- preset here would make the next switch back to it a no-op.
		upscale_active_preset = nil
		upscale_active_key = 'off'
	end
	if off_note then
		notify('Upscaling off here', off_note) -- in place of "Upscale: off"
	end
	publish_family(upscale_active_preset)
	update_upscale_button()
	schedule_measure()
end

-- Both open menus show a change at once (uosc ignores update-menu for a menu
-- that is not open; the Settings menu follows user-data/gpu-toggles/quality).
local function update_menus()
	open_upscale_menu(true)
	publish_quality()
end

-- The render passes' GPU time per frame, in ms (sum of every fresh pass's
-- average), or nil without timers (--vo=null) or frames.
local function read_render_ms()
	local vp = mp.get_property_native('vo-passes')
	local fresh = type(vp) == 'table' and vp.fresh
	if type(fresh) ~= 'table' or #fresh == 0 then
		return nil
	end
	local ns = 0
	for _, pass in ipairs(fresh) do
		ns = ns + (tonumber(pass.avg) or 0)
	end
	return ns > 0 and ns / 1e6 or nil
end

local measure_timer, measure_tries = nil, 0
local told = {} -- slow-chain banners, once per chain, screen and source size

local function measure()
	measure_timer = nil
	local preset = upscale_active_preset
	if not preset or not opts.remember then
		return
	end
	-- not while paused or buffering, nor while the background shader warm-up
	-- draws on the same GPU (Scripts/shader-cache)
	local sc = mp.get_property_native('user-data/shader-cache') or {}
	local ms = nil
	if not (mp.get_property_native('pause') or mp.get_property_native('core-idle') or sc.state == 'warming') then
		ms = read_render_ms()
	end
	forget_display_scale()
	local key = cost_key(preset.id)
	if not ms or not key then
		measure_tries = measure_tries + 1
		if key and measure_tries < 20 then
			measure_timer = mp.add_timeout(MEASURE_AFTER, measure)
		end
		return
	end
	ms = math.floor(ms * 10 + 0.5) / 10
	costs[key] = ms
	save_upscale_state()
	local budget = frame_budget_ms()
	if ms > budget and not told[key] then
		told[key] = true
		local fast = preset == UPSCALE_ANIME or preset == UPSCALE_MOVIE_FSRCNNX -- a faster chain exists
		local spent = string.format('%s took %.1f ms per frame here (%.0f fit)', short_name(preset), ms, budget)
		if quality == 'auto' then
			apply_upscale(false) -- auto_pick(): the fast chain now, or none when this was it
			if upscale_active_preset then
				notify('Upscaling quality: Fast', spent .. ' · Settings to change')
			else
				notify('Upscaling off here', spent .. ' · Settings > Upscaling quality runs it anyway')
			end
		elseif fast then
			notify('Upscaling may stutter', spent .. ' · Settings > Upscaling quality > Fast')
		else
			notify('Upscaling may stutter', spent .. ' · Shift+A / Shift+Y turns it off')
		end
	end
	update_menus()
end

-- Times the chain on screen, once per chain, screen and source size.
schedule_measure = function()
	if measure_timer then
		measure_timer:kill()
		measure_timer = nil
	end
	measure_tries = 0
	if upscale_active_preset and opts.remember and not cost_of(upscale_active_preset) then
		measure_timer = mp.add_timeout(MEASURE_AFTER, measure)
	end
end

local function cycle_upscale()
	local n = (upscale_mode + 1) % UPSCALE_MODE_COUNT
	-- Auto is identical to Off on anything but FastStream content, so stepping
	-- onto it there would be an invisible, dead keypress: skip it. On a local
	-- file the cycle is Off -> Anime -> Movie -> Off.
	if n == 1 and not is_faststream_content() then
		n = 2
	end
	upscale_mode = n
	apply_upscale(true)
end

-- Shift+A / Shift+Y: each key flips its own preset on and off. "On" means that
-- chain is what is actually running, so Auto having picked Anime on a
-- FastStream anime stream counts as Anime being on. Switching to the other
-- preset replaces the chain in one step - the two can never run together.
local function toggle_anime()
	upscale_mode = is_anime_preset(upscale_active_preset) and 0 or 2
	apply_upscale(true)
end

local function toggle_movie()
	upscale_mode = is_movie_preset(upscale_active_preset) and 0 or 3
	apply_upscale(true)
end

-- script-message-to gpu_toggles set-upscale <0..3>
local function set_upscale(index)
	local n = tonumber(index)
	if n and n % 1 == 0 and n >= 0 and n < UPSCALE_MODE_COUNT then
		upscale_mode = n
		apply_upscale(true)
	else
		msg.warn('set-upscale: invalid index ' .. tostring(index))
	end
end

-- script-message-to gpu_toggles set-movie-sharpness <auto|0..4>
-- Changes the strength, and remembers it for the next start (see opts). If a Movie chain is
-- running it is re-applied at once: a level change within "on" only updates
-- glsl-shader-opts (no recompile), Off <-> on swaps the shader list.
local function set_movie_sharpness(value)
	local v = parse_sharpness(value)
	if not v then
		msg.warn('set-movie-sharpness: invalid value ' .. tostring(value))
		return
	end
	movie_sharpness = v
	save_sharpness(v)
	if is_movie_preset(upscale_active_preset) then
		apply_upscale(false)
	end
	notify(
		'Movie sharpness: ' .. setting_label(),
		not is_movie_preset(upscale_active_preset) and 'used when Movie is on' or nil
	)
	update_upscale_button()
	update_menus()
end

local function set_anime_lines(value)
	if value ~= 'crisp' and value ~= 'drawn' then
		msg.warn('set-anime-lines: invalid value ' .. tostring(value))
		return
	end
	anime_lines = value
	save_upscale_state()
	if is_anime_preset(upscale_active_preset) then
		apply_upscale(false)
	end
	notify(
		'Anime lines: ' .. anime_lines_label(),
		not is_anime_preset(upscale_active_preset) and 'used when Anime is on' or nil
	)
	update_upscale_button()
	update_menus()
end

-- What runs now, for the banners of the settings below.
local function running_detail()
	return upscale_active_preset and ('now ' .. short_name(upscale_active_preset)) or 'used when upscaling is on'
end

-- script-message-to gpu_toggles set-quality <auto|high|fast>
local function set_quality(value)
	if not QUALITIES[value] then
		msg.warn('set-quality: invalid value ' .. tostring(value))
		return
	end
	quality = value
	chosen_quality = value
	save_upscale_state()
	-- also when Auto has it off right now: a choice made here may turn it back on
	if upscale_mode ~= 0 then
		apply_upscale(false)
	end
	notify('Upscaling quality: ' .. quality_label(), running_detail())
	update_menus()
end

-- script-message-to gpu_toggles set-screen <auto|WxH>
local function set_screen(value)
	if value ~= 'auto' and not (type(value) == 'string' and value:match('^%d+x%d+$')) then
		msg.warn('set-screen: invalid value ' .. tostring(value))
		return
	end
	screen = value
	save_upscale_state()
	forget_display_scale()
	-- also when Auto has it off right now: a choice made here may turn it back on
	if upscale_mode ~= 0 then
		apply_upscale(false)
	end
	notify('Screen for upscaling: ' .. screen_label(), running_detail())
	update_menus()
end

-- script-message-to gpu_toggles forget-measurements: Auto starts from High
-- again and measures anew (a new GPU, or a driver that changed the speed).
local function forget_measurements()
	costs = {}
	told = {}
	save_upscale_state()
	-- also when Auto has it off right now: a choice made here may turn it back on
	if upscale_mode ~= 0 then
		apply_upscale(false)
	end
	notify('Measurements cleared', 'the next upscaled video is measured again')
	update_menus()
end

-- script-message-to gpu_toggles set-cost <chain id> <ms>: a measurement by hand
-- (the tests: --vo=null has no GPU timers). For the current screen and source.
local function set_cost(id, value)
	local ms = tonumber(value)
	local key = cost_key(tostring(id))
	if not key or not ms or ms <= 0 then
		msg.warn('set-cost: needs a chain id, a number and a known screen + source size')
		return
	end
	costs[key] = ms
	save_upscale_state()
	-- also when Auto has it off right now: a choice made here may turn it back on
	if upscale_mode ~= 0 then
		apply_upscale(false)
	end
	update_menus()
end

-- ---- Key bindings -----------------------------------------------------------
-- input.conf / uosc menus reach these via "script-binding gpu_toggles/<name>";
-- that command only finds bindings added through add_key_binding, NOT
-- register_script_message below - the two are separate mpv mechanisms. key=nil
-- means "name only": the actual key (Shift+A etc.) is bound in input.conf.
-- Every handler goes through entry(), so each action reads the display scale
-- fresh, at most once (see forget_display_scale()): a new file or a window
-- moved to another display is picked up by the next action. entry() also
-- counts finished actions in user-data/gpu-toggles/applied: the shader warm-up
-- (Scripts/shader-cache/warmup.lua) waits on that counter instead of a fixed
-- delay to know that the switch it asked for has been applied.
local actions_done = 0
local function entry(fn)
	return function(...)
		forget_display_scale()
		fn(...)
		actions_done = actions_done + 1
		mp.set_property_native('user-data/gpu-toggles/applied', actions_done)
	end
end

mp.add_key_binding(nil, 'cycle-upscale', entry(cycle_upscale))
mp.add_key_binding(nil, 'toggle-anime', entry(toggle_anime))
mp.add_key_binding(nil, 'toggle-movie', entry(toggle_movie))

-- ---- Script messages (bound in input.conf / uosc menu) --------------------
mp.register_script_message('cycle-upscale', entry(cycle_upscale))
mp.register_script_message('set-upscale', entry(set_upscale))
mp.register_script_message(
	'open-upscale-menu',
	entry(function()
		open_upscale_menu(false)
	end)
)
mp.register_script_message('set-movie-sharpness', entry(set_movie_sharpness))
mp.register_script_message('set-anime-lines', entry(set_anime_lines))
mp.register_script_message('set-quality', entry(set_quality))
mp.register_script_message('set-screen', entry(set_screen))
mp.register_script_message('forget-measurements', entry(forget_measurements))
mp.register_script_message('set-cost', entry(set_cost))
-- Scripts/settings.lua asks for the current state when its menu opens. Not
-- through entry(): it is no action (the warm-up counts actions).
mp.register_script_message('publish-quality', function()
	forget_display_scale()
	publish_quality()
end)

-- Re-apply the upscale mode on every file load (apply_upscale() no-ops if the
-- resulting preset hasn't changed): mode 1 (Auto) re-evaluates content type,
-- so switching from an anime file to a movie file (or back) swaps the preset
-- automatically; a named choice (Anime/Movie) is sticky across files on
-- purpose.
mp.register_event(
	'file-loaded',
	entry(function()
		apply_upscale(false)
	end)
)

-- Initial button state, in case uosc loads after this script (same defensive
-- delay as scripts/speed-button.lua's "speed" button). Not through entry():
-- entry() counts an action in user-data/gpu-toggles/applied, which the shader
-- warm-up waits on - an extra count would make its steps look done one action
-- early.
mp.add_timeout(0.5, function()
	forget_display_scale()
	update_upscale_button()
end)
