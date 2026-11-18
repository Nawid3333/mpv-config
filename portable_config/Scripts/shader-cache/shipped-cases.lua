-- shipped-cases.lua - what real playback needs beyond warmup.lua's matrix, drawn after it in a full warm-up.
-- Changing this list -> bump fingerprint.lua's WARMUP_VERSION.

local function clip(base, w, h, extra)
	local c = { w = w, h = h }
	for k, v in pairs(base) do
		c[k] = v
	end
	for k, v in pairs(extra or {}) do
		c[k] = v
	end
	return c
end

local SDR8 = { codec = 'libx264', pix = 'yuv420p', matrix = 'bt.709', primaries = 'bt.709', gamma = 'bt.1886' }
local SDR8_HEVC = { codec = 'libx265', pix = 'yuv420p', matrix = 'bt.709', primaries = 'bt.709', gamma = 'bt.1886' }
local SDR10 = { codec = 'libx265', pix = 'yuv420p10le', matrix = 'bt.709', primaries = 'bt.709', gamma = 'bt.1886' }
local GRAIN10 = {
	codec = 'libsvtav1',
	pix = 'yuv420p10le',
	grain = true,
	matrix = 'bt.709',
	primaries = 'bt.709',
	gamma = 'bt.1886',
}
local SW420_601 = { codec = 'ffv1', pix = 'yuv420p', matrix = 'bt.601', primaries = 'bt.601-625', gamma = 'bt.1886' }
local SW444 = { codec = 'ffv1', pix = 'yuv444p', matrix = 'bt.709', primaries = 'bt.709', gamma = 'bt.1886' }
local BT2020_SDR =
	{ codec = 'libx265', pix = 'yuv420p10le', matrix = 'bt.2020-ncl', primaries = 'bt.2020', gamma = 'bt.1886' }
local P3 = { codec = 'libx264', pix = 'yuv420p', matrix = 'bt.709', primaries = 'display-p3', gamma = 'srgb' }
local HDR10 = { codec = 'libx265', pix = 'yuv420p10le', matrix = 'bt.2020-ncl', primaries = 'bt.2020', gamma = 'pq' }
local HLG = { codec = 'libx265', pix = 'yuv420p10le', matrix = 'bt.2020-ncl', primaries = 'bt.2020', gamma = 'hlg' }
-- stills: what mpv's own decoders make of a JPEG (full-range 4:2:0 / 4:4:4,
-- bt.601, sRGB), a PNG (rgb24, rgba, gray) and a GIF (bgra)
local JPEG420 = { codec = 'mjpeg', pix = 'yuvj420p' }
local JPEG444 = { codec = 'mjpeg', pix = 'yuvj444p' }
local PNG_RGB = { codec = 'png', pix = 'rgb24' }
local PNG_RGBA = { codec = 'png', pix = 'rgba' }
local PNG_GRAY = { codec = 'png', pix = 'gray' }
local GIF = { codec = 'gif', pix = 'bgra' }

local D3D, SW = 'd3d11va-copy', 'no'

local cases = {}
local function add(t)
	cases[#cases + 1] = t
end
local function chains(c, hwdec, list, extra)
	for _, chain in ipairs(list) do
		local t = { clip = c, hwdec = hwdec, chain = chain }
		for k, v in pairs(extra or {}) do
			t[k] = v
		end
		add(t)
	end
end
local ALL = { 'off', 'anime', 'movie' }

-- A window at the video's own size: no scaling pass at all (each surface kind)
add({ clip = clip(SDR8, 1920, 1080), hwdec = D3D, chain = 'off', unscaled = true })
add({ clip = clip(SDR10, 1920, 1080), hwdec = D3D, chain = 'off', unscaled = true })
add({ clip = clip(SW420_601, 640, 360), hwdec = SW, chain = 'off', unscaled = true })
add({ clip = clip(SW444, 1920, 1080), hwdec = SW, chain = 'off', unscaled = true })

-- The right-click menu's video settings, on a 1080p file
add({ clip = clip(SDR8, 1920, 1080), hwdec = D3D, chain = 'off', deband = false })
add({ clip = clip(SDR8, 1920, 1080), hwdec = D3D, chain = 'off', eq = { gamma = 2 } })
add({
	clip = clip(SDR8, 1920, 1080),
	hwdec = D3D,
	chain = 'off',
	eq = { contrast = 2, brightness = 2, saturation = 2, hue = 2 },
})
add({ clip = clip(SDR8, 1920, 1080), hwdec = D3D, chain = 'off', rotate = 90 })
add({ clip = clip(SDR8, 1920, 1080), hwdec = D3D, chain = 'off', rotate = 180 })
add({ clip = clip(SDR8, 1920, 1080), hwdec = D3D, chain = 'off', overlay = true })
add({ clip = clip(SDR8, 1920, 1080), hwdec = D3D, chain = 'off', subs = true })

-- Strong downscales: 8K on a 1440p screen; a vertical phone video through Movie
chains(clip(SDR8_HEVC, 7680, 4320), D3D, { 'off', 'movie' })
add({ clip = clip(SDR8, 1080, 1920), hwdec = D3D, chain = 'movie' })

-- Shrunk into a smaller window: each new downscaler tap count is a new shader (hermite: 2*ceil(1/ratio) taps).
-- One ratio per tap step, for the three surfaces real files come in; Off only, as the chains run before it.
for _, s in ipairs({
	{ clip(SDR8, 1920, 1080), D3D },
	{ clip(SDR10, 1920, 1080), D3D },
	{ clip(HDR10, 1920, 1080), D3D },
}) do
	for _, ratio in ipairs({ 0.45, 0.3, 0.23, 0.18, 0.15, 0.14 }) do
		add({ clip = s[1], hwdec = s[2], chain = 'off', ratio = ratio })
	end
end

-- AV1 film grain, applied by the renderer (vd-lavc-film-grain=auto)
chains(clip(GRAIN10, 1920, 1080), D3D, ALL)
add({ clip = clip(GRAIN10, 1920, 1080), hwdec = D3D, chain = 'off', unscaled = true })

-- Software-decoded: a PAL DVD (anamorphic 4:2:0, bt.601) and 4:4:4
chains(clip(SW420_601, 720, 576, { sar = '64/45' }), SW, ALL)
chains(clip(SW444, 1920, 1080), SW, { 'off', 'anime' })

-- Colour: bt.2020 SDR, Display P3
add({ clip = clip(BT2020_SDR, 3840, 2160), hwdec = D3D, chain = 'off' })
chains(clip(P3, 1920, 1080), D3D, ALL)
add({ clip = clip(P3, 1920, 1080), hwdec = D3D, chain = 'off', unscaled = true })

-- HDR10 (tone-mapped to this SDR screen, with peak detection): 4K shrunk,
-- 1080p enlarged, the equalizer
chains(clip(HDR10, 3840, 2160), D3D, ALL)
add({ clip = clip(HDR10, 3840, 2160), hwdec = D3D, chain = 'off', eq = { gamma = 2 } })
chains(clip(HDR10, 1920, 1080), D3D, ALL)

-- HLG (phones, broadcast)
chains(clip(HLG, 3840, 2160), D3D, ALL)
chains(clip(HLG, 1920, 1080), D3D, ALL)
add({ clip = clip(HLG, 1920, 1080), hwdec = D3D, chain = 'off', unscaled = true })

-- Dolby Vision (profiles 5, 8.1, 8.4): no encoder here writes an RPU, so these are real clips (clips/README.txt).
-- as_size: zoomed to a 4K source's scale here; Off and Anime only (Movie goes by the real display scale).
for _, f in ipairs({ 'dv-p5.mp4', 'dv-p8.1.mp4', 'dv-p8.4.mp4' }) do
	local dv = { file = 'clips/' .. f, w = 1920, h = 1080 }
	chains(dv, D3D, ALL)
	chains(dv, D3D, { 'off', 'anime' }, { as_size = { 3840, 2160 } })
end

-- Stills, cover art, GIF
chains(clip(JPEG420, 4000, 3000), SW, { 'off', 'anime' })
add({ clip = clip(JPEG420, 720, 720), hwdec = SW, chain = 'off' })
add({ clip = clip(JPEG444, 1000, 1000), hwdec = SW, chain = 'off' })
chains(clip(PNG_RGB, 1920, 1080), SW, { 'off', 'anime' })
chains(clip(PNG_RGBA, 1250, 752), SW, { 'off', 'anime' })
chains(clip(PNG_GRAY, 800, 600), SW, { 'off', 'anime' })
chains(clip(GIF, 480, 270), SW, { 'off', 'anime' })

return cases
