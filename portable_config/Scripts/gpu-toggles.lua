-- gpu-toggles.lua - shader upscaling (Off, Auto, Anime, Movie): one place for the key, the menu and the toolbar button.
-- Auto picks Anime or Movie by the FastStream content tag; other files get shaders only when picked.

local mp = require('mp')
local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')
-- the FastStream tags in the URL fragment (AGENTS.md, "FastStream contract")
local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))

-- script-opts/gpu_toggles.conf; the menus' choices (~~state/movie-sharpness.json, upscale.json) win over it.
-- remember=no (the shader warm-ups) neither reads nor writes the remembered choices.
local opts = {
	movie_sharpness = 'auto',
	quality = 'auto',
	remember = true,
}
options.read_options(opts, 'gpu_toggles')

local SHARPNESS_FILE = mp.command_native({ 'expand-path', '~~state/' }) .. '/movie-sharpness.json'
local UPSCALE_FILE = mp.command_native({ 'expand-path', '~~state/' }) .. '/upscale.json'
local statefile = dofile(mp.command_native({ 'expand-path', '~~/script-modules/state-file.lua' }))

local SHADER_DIR = mp.command_native({ 'expand-path', '~~/shaders' })

-- The last whole fs-content= item of the URL fragment (faststream-fragment.lua), up to its first non-letter.
---@param path string|nil
---@return string|nil
local function fs_content(path)
	local content = fragment.value(path, 'fs-content=')
	-- %a+: an empty item ("fs-content=") is no tag
	return content and content:match('^(%a+)')
end

local function is_anime_content()
	return fs_content(mp.get_property('path', '')) == 'anime'
end

-- Any fs-content tag: a FastStream stream. Auto upscales only those; a local file gets shaders only when picked.
local function is_faststream_content()
	return fs_content(mp.get_property('path', '')) ~= nil
end

-- ---- Upscale (2 user-facing presets: Anime / Movie) -----------------------
-- Anime: Anime4K C+A, chosen by eye over ArtCNN and CuNNy; its AutoDownscalePre stages adapt it to the real ratio.
-- Movie: FSRCNNX only from MOVIE_FSRCNNX_MIN_SCALE (2x) to the display, below it SSimSuperRes (doc/scripts.md).
-- No FSR and no vf-based upscalers (doc/scripts.md).
-- Both Movie chains end with adaptive-sharpen on the OUTPUT hook (after all scaling), left out when not enlarged.
-- Both Movie chains start with CfL_Prediction: 4:2:0 colour is enlarged twice the luma ratio.
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
-- Quality Fast: Anime4K's own low-end template of the same Mode C+A (M for VL, S for M), about half the work.
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
-- `dscale` applies while the preset is active; `sharpen` appends SHARPEN_SHADER at the current strength.
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

-- Fixed strengths offered next to Auto (adaptive-sharpen's curve_height); 0 drops the shader.
local SHARPEN_SHADER = 'adaptive-sharpen.glsl'
local SHARPEN_OPT = 'adaptive-sharpen/curve_height'
local SHARPEN_LEVELS = {
	{ name = 'Off', value = 0, note = 'softest, closest to the source' },
	{ name = 'Low', value = 0.5 },
	{ name = 'Medium', value = 1.0 },
	{ name = 'High', value = 1.5, note = 'crispest, may look harsh' },
}
local SHARPEN_MAX = 4.0

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

local function save_sharpness(v)
	if not opts.remember then
		return
	end
	local json = utils.format_json({ sharpness = v })
	local ok, err = false, 'cannot serialize the sharpness'
	if json then
		ok, err = statefile.write(SHARPNESS_FILE, json)
	end
	if not ok then
		msg.warn(err)
	end
end

local movie_sharpness = load_sharpness() or parse_sharpness(opts.movie_sharpness) or SHARPEN_AUTO

local function sharpness_label(v)
	for _, level in ipairs(SHARPEN_LEVELS) do
		if math.abs(level.value - v) < 1e-6 then
			return level.name
		end
	end
	return string.format('%.2f', v)
end

-- Starts at Auto: the right preset on FastStream content with no clicks, no shaders on a local file.
local upscale_mode = 1

-- ---- Upscaling quality and the screen -------------------------------------
-- ~~state/upscale.json, per PC: quality, screen ('auto' or 'WxH': the size the choices are made for), anime_lines,
-- and costs: each chain's GPU ms per frame here (vo-passes), keyed 'anime-high|2560x1440|1080p'.
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
-- Anime lines: 'crisp' runs Anime4K's Restore step (crisper, thinner lines), 'drawn' leaves it out.
local anime_lines = saved.anime_lines or 'crisp'

local function save_upscale_state()
	if not opts.remember then
		return
	end
	local json =
		utils.format_json({ quality = chosen_quality, screen = screen, costs = costs, anime_lines = anime_lines })
	local ok, err = false, 'cannot serialize the upscale state'
	if json then
		ok, err = statefile.write(UPSCALE_FILE, json)
	end
	if not ok then
		msg.warn(err)
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
	-- width/height are before rotation: a portrait video shown upright is a downscale, not 1.33x.
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

-- Read at most once per action (entry() forgets it): display-width/height wait for the video thread.
local current_display = nil

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

-- Auto = display scale - 1, clamped: across 1.33x-3x it tracks the clean master's own edge sharpness.
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
-- Auto times a high chain's render passes (vo-passes) once per screen and source size after MEASURE_AFTER s;
-- over BUDGET_SHARE of a frame's time it takes the fast chain from then on, with a banner.
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

-- What is loaded: the list depends on the scale and the sharpness too, not only the preset.
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
		return true
	end
	shader_opts[SHARPEN_OPT] = want
	local ok, err = mp.set_property_native('glsl-shader-opts', shader_opts)
	if not ok then
		msg.warn('could not set glsl-shader-opts: ' .. tostring(err))
	end
	return ok
end

-- Auto's preset: nil unless FastStream content, then by content type.
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

-- Mode 1 re-evaluates on every call, so it follows a new file's content type.
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

-- Missing files are dropped: mpv aborts the whole list if one file fails to load.
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

-- dscale as configured at startup: everything but a preset with its own dscale gets it back.
local BASE_DSCALE = mp.get_property('dscale')

-- A banner (notify.lua; the same id replaces the last), e.g. "Upscale: Movie" over its chain.
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
		-- Nothing of this preset on disk: clear the list (no previous chain running unseen), dscale back, report it.
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
-- Managed button (button:upscale); uosc's set-button repaints every time, so an unchanged one is not sent.
local last_button_json = {}

local function set_uosc_button(name, data)
	local json, err = utils.format_json(data)
	if not json then
		msg.error('Failed to format ' .. name .. ' button JSON: ' .. tostring(err))
		return
	end
	if last_button_json[name] == json then
		return
	end
	-- remembered only once sent: before uosc has started there is nobody to send to
	if mp.commandv('script-message-to', 'uosc', 'set-button', name, json) then
		last_button_json[name] = json
	end
end

local upscale_active_preset = nil
local upscale_active_key = 'off'

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

-- Badges stay at 4 chars: uosc draws a badge in the button's fixed icon box, a longer one overlaps the next.
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
		-- Auto on a non-FastStream file says "Off"; the mode stays 1 so a FastStream stream next gets its preset.
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

-- uosc menu items, with keep_open; settings.lua embeds them from user-data/gpu-toggles/quality.
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
	-- Auto is offered only for FastStream content; elsewhere it is Off, so Off is highlighted.
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
local schedule_measure

-- `announce`: a user's change; the per-file re-evaluation stays quiet when nothing changed.
local function apply_upscale(announce)
	local preset = preset_for_mode(upscale_mode)
	-- "(Auto)" shows Auto apart from a direct pick that resolves to the same chain.
	local suffix = upscale_mode == 1 and ' (Auto)' or nil
	-- off because quality Auto measured even the fast chain too slow here
	local off_note = not preset and auto_off_note() or nil

	if preset == upscale_active_preset and chain_key(preset) == upscale_active_key then
		-- The same chain: no recompile, but a user's change still shows a banner (Auto and Anime can be one chain).
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
		-- Not applied and the list cleared: recording it would make the next switch back a no-op.
		upscale_active_preset = nil
		upscale_active_key = 'off'
	end
	if off_note then
		notify('Upscaling off here', off_note)
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
local told = {}

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
		local fast = preset == UPSCALE_ANIME or preset == UPSCALE_MOVIE_FSRCNNX
		local spent = string.format('%s took %.1f ms per frame here (%.0f fit)', short_name(preset), ms, budget)
		if quality == 'auto' then
			apply_upscale(false)
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
	-- Auto is Off on non-FastStream files: the cycle skips it there (Off -> Anime -> Movie).
	if n == 1 and not is_faststream_content() then
		n = 2
	end
	upscale_mode = n
	apply_upscale(true)
end

-- Shift+A / Shift+Y flip their own preset (Auto's pick counts as on); the other preset is replaced in one step.
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
-- Remembered; a running Movie chain only updates glsl-shader-opts (Off <-> on swaps the list).
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

-- Shift+S: Anime's lines or Movie's sharpness, without the menu; with no chain running it changes nothing.
local function cycle_tuning()
	local choices = {}
	local mark = function(label, on)
		choices[#choices + 1] = on and ('[' .. label .. ']') or label
	end
	if is_anime_preset(upscale_active_preset) then
		set_anime_lines(anime_lines == 'crisp' and 'drawn' or 'crisp')
		mark('Crisp', anime_lines == 'crisp')
		mark('As drawn', anime_lines == 'drawn')
		notify('Anime lines: ' .. anime_lines_label(), table.concat(choices, ' · '))
	elseif is_movie_preset(upscale_active_preset) then
		---@type (string|number)[] 'auto', then the fixed strengths
		local order = { SHARPEN_AUTO }
		for _, level in ipairs(SHARPEN_LEVELS) do
			order[#order + 1] = level.value
		end
		-- a value set by hand outside the list (script-opts) goes on to Auto
		local next_value = order[1]
		for i, v in ipairs(order) do
			if v == movie_sharpness then
				next_value = order[i % #order + 1]
				break
			end
		end
		set_movie_sharpness(next_value)
		mark('Auto', movie_sharpness == SHARPEN_AUTO)
		for _, level in ipairs(SHARPEN_LEVELS) do
			mark(level.name, movie_sharpness == level.value)
		end
		notify('Movie sharpness: ' .. setting_label(), table.concat(choices, ' · '))
	else
		notify('No upscaling running', 'Shift+A Anime or Shift+Y Movie, then Shift+S tunes it')
	end
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
-- script-binding finds only add_key_binding names (not script messages); key=nil: the key lives in input.conf.
-- entry(): each action reads the display at most once and counts in user-data/gpu-toggles/applied (the warm-up waits).
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
mp.add_key_binding(nil, 'cycle-tuning', entry(cycle_tuning))

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
mp.register_script_message('cycle-tuning', entry(cycle_tuning))
mp.register_script_message('set-quality', entry(set_quality))
mp.register_script_message('set-screen', entry(set_screen))
mp.register_script_message('forget-measurements', entry(forget_measurements))
mp.register_script_message('set-cost', entry(set_cost))
-- settings.lua asks for the state when its menu opens; not through entry(), as it is no action.
mp.register_script_message('publish-quality', function()
	forget_display_scale()
	publish_quality()
end)

-- Every file load re-applies: Auto follows the content type, a named choice stays across files.
mp.register_event(
	'file-loaded',
	entry(function()
		apply_upscale(false)
	end)
)

-- Initial button state: not through entry(), whose count the warm-up waits on.
-- Sent again every half second until uosc has it (at most 10 s).
local initial_tries = 0
local initial_push
initial_push = mp.add_periodic_timer(0.5, function()
	initial_tries = initial_tries + 1
	if initial_tries == 1 then
		forget_display_scale()
	end
	update_upscale_button()
	if last_button_json.upscale or initial_tries >= 20 then
		initial_push:kill()
	end
end)
