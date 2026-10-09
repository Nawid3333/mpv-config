-- mpv.conf is really in effect, for local files AND FastStream content.
-- Guards the 2026-09-21 bug: a profile section sitting mid-file silently
-- scoped every option below it to FastStream streams only. Reads each option
-- back from the running player for a local file, a #fs-content= file, and a
-- local file again. A FastStream file decodes like any other: d3d11va-copy,
-- never vulkan (2026-10-04: vulkan decoding lost the GPU device - mpv.conf's
-- hwdec section).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

-- option -> expected value as mp.get_property() prints it. vo is not here: the
-- runner overrides it with --vo=null (tests/run-tests.ps1 checks the conf text).
local GLOBAL = {
	['window-dragging'] = 'no',
	['border'] = 'yes', -- native title bar: Windows 11 move/snap/Snap Layouts
	['title-bar'] = 'yes',
	['keep-open'] = 'yes',
	['osc'] = 'no',
	['osd-bar'] = 'no',
	['cursor-autohide'] = '1000',
	['video-sync'] = 'audio',
	['gpu-context'] = 'winvk,d3d11', -- d3d11 only where Vulkan does not start (2026-10-09)
	['hdr-compute-peak'] = 'yes',
	['sub-auto'] = 'fuzzy',
	['cache'] = 'yes', -- the buffer size and waits: a per-PC setting (test-settings.lua)
	['swapchain-depth'] = '4',
}

local function check_all(where, hwdec)
	for name, want in pairs(GLOBAL) do
		H.eq(where .. ': ' .. name, mp.get_property('options/' .. name), want)
	end
	H.eq(where .. ': hwdec', mp.get_property('options/hwdec'), hwdec)
end

-- The languages and the HDR brightness are per-PC settings since 2026-10-09
-- (Scripts/settings.lua): tests/headless/test-settings.lua has them.

H.run(function()
	check_all('local file', 'd3d11va-copy,no')
	H.load(H.media_path('fs-movie/film#fs-content=movie&fs-id=0f0f0f0f0f0f0f0f.mkv'))
	check_all('FastStream file', 'd3d11va-copy,no')
	H.load(H.media_path('plain/clip.mkv'))
	check_all('local file after FastStream', 'd3d11va-copy,no')
end)
