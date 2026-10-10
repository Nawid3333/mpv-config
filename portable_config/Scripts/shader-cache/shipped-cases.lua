-- shipped-cases.lua - what real playback needs beyond warmup.lua's fixed matrix,
-- FOUND BY MEASURING (2026-10-02), so a full warm-up draws it before any video
-- does. Loaded with dofile() by warmup.lua and drawn after the matrix: one step
-- each, a 1 s clip made once with mpv's own encoder (cases.lua), decoded the
-- same way, drawn through the same chain.
--
-- Where the list came from: the tests' gap hunt (2026-10-02 to 2026-10-05)
-- warmed an EMPTY cache exactly as the player does, then played a corpus of
-- every kind of video and picture (codecs, bit depths, 4:2:0/4:4:4,
-- bt.601/bt.709/bt.2020/P3, HDR10, HLG, Dolby Vision, film grain, 144p to 8K,
-- stills, cover art) under every chain, window size and menu setting; every
-- condition that still compiled a shader became a case here, until a run came
-- out clean. The hunt was removed with the player's capture after the owner's
-- measurement (mpv issue #39); the list is kept by hand now. A kind of video
-- that still stutters on its first start after a full warm-up (a log with
-- --msg-level=vo/gpu-next/libplacebo=debug then shows "shaderc compile status"
-- lines, as warmup.lua counts them) is a new case: add it here and bump
-- fingerprint.lua's WARMUP_VERSION.
--
-- A case: `clip` (cases.clip_recipe(): size, FFmpeg pixel format, encoder,
-- colour tags, SAR, film grain), hwdec, chain ('off' | 'anime' | 'movie'),
-- and optionally:
--   unscaled = true   drawn 1:1 (video-unscaled): a window at the video's own
--                     size, which is how mpv opens a local file here
--   deband = false    eq = { gamma = 2, ... }    rotate = 90
--   overlay = true    an RGBA bitmap over the video (thumbfast's thumbnails,
--                     picture subtitles)
--   subs = true       a text subtitle line (libass)
--   as_size = {w, h}  drawn at the scale a source of that size has in this
--                     window (video-zoom on the fitted clip)
-- A clip can also be a shipped FILE (`clip.file`, relative to this folder,
-- with its w/h) where no encoder can make it: Dolby Vision.
-- Otherwise the clip is fitted to the window, as in fullscreen. The clip has
-- the REAL size the case stands for: gpu-toggles picks Movie's passes and its
-- sharpening from the true display scale, so a smaller clip zoomed up would
-- draw a different chain.
--
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

-- clip kinds
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
-- the same clip and decoder through each chain
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

-- Shrunk into a smaller window: the downscaler's kernel widens with the
-- shrink, and each new tap count is a new shader (an 8K film in a window at
-- x0.31 compiled where fullscreen x0.33 did not). One ratio per tap step
-- (hermite, mpv's dscale: 2*ceil(1/ratio) taps -> 6, 8, 10, 12, 14, 16), for
-- the three surfaces real files come in (a fourth, vulkan-decoded 8-bit, went
-- with vulkan decoding on 2026-10-04). Off only: the chains run before it.
-- The 14-tap step (1/7 < ratio <= 1/6) was missing until 2026-10-10: after
-- x0.18 and x0.14 had been drawn, a 1080p video shrunk to x0.15 compiled 6
-- shaders, and x0.155 / x0.16 nothing more (measured with the pinned build).
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
-- 1080p enlarged, the equalizer (the vulkan-decoded cases went on 2026-10-04,
-- with vulkan decoding: mpv.conf's hwdec section)
chains(clip(HDR10, 3840, 2160), D3D, ALL)
add({ clip = clip(HDR10, 3840, 2160), hwdec = D3D, chain = 'off', eq = { gamma = 2 } })
chains(clip(HDR10, 1920, 1080), D3D, ALL)

-- HLG (phones, broadcast)
chains(clip(HLG, 3840, 2160), D3D, ALL)
chains(clip(HLG, 1920, 1080), D3D, ALL)
add({ clip = clip(HLG, 1920, 1080), hwdec = D3D, chain = 'off', unscaled = true })

-- Dolby Vision (profiles 5, 8.1, 8.4): the RPU reshaping is a pass of its own
-- and no encoder here writes an RPU, so these clips are real files - 12 frames
-- cut losslessly from Jellyfin's test videos (clips/README.txt: source and
-- licence). 1080p enlarged, and shrunk the way a 4K film is (as_size: the
-- clip zoomed to the scale a 3840x2160 source has here; Off and Anime only -
-- Movie takes its passes from the real display scale, see the header).
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
