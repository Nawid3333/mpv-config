-- mpv.conf is really in effect, for local files AND FastStream content.
-- Guards the 2026-09-21 bug: a profile section sitting mid-file silently
-- scoped every option below it to FastStream streams only. Reads each option
-- back from the running player for a local file, a #fs-content= file, and a
-- local file again (profile-restore=copy must put hwdec back).
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
	['gpu-context'] = 'winvk',
	['hdr-compute-peak'] = 'yes',
	['sub-auto'] = 'fuzzy',
	['slang'] = 'de,en',
	['alang'] = 'de,en',
	['cache'] = 'yes',
	['demuxer-max-bytes'] = '1073741824',
	['demuxer-max-back-bytes'] = '134217728',
	['cache-pause-initial'] = 'yes',
	['cache-pause-wait'] = '3.000000',
	['swapchain-depth'] = '4',
}

local function check_all(where, hwdec)
	for name, want in pairs(GLOBAL) do
		H.eq(where .. ': ' .. name, mp.get_property('options/' .. name), want)
	end
	H.eq(where .. ': hwdec', mp.get_property('options/hwdec'), hwdec)
end

-- target-peak=350 for HDR sources only ([hdr-target-peak]): set for every
-- file it dimmed all SDR video to ~78 % signal on the SDR desktop (2026-10-02)
local function peak()
	return mp.get_property('options/target-peak')
end

local function gamma()
	return mp.get_property('video-params/gamma')
end

H.run(function()
	check_all('local file', 'd3d11va-copy,no')
	H.eq('SDR file: target-peak auto (full brightness)', peak(), 'auto')
	H.load(H.media_path('fs-movie/film#fs-content=movie&fs-id=0f0f0f0f0f0f0f0f.mkv'))
	check_all('FastStream file', 'vulkan,d3d11va-copy,no')
	H.load(H.media_path('plain/clip.mkv'))
	check_all('local file after FastStream', 'd3d11va-copy,no')

	H.load(H.media_path('hdr/pq.mkv'))
	H.expect('the HDR clip is PQ', gamma, 'pq')
	H.expect('HDR file: target-peak 350 (the panel, for tone mapping)', peak, '350')
	H.load(H.media_path('plain/clip.mkv'))
	H.expect('SDR file after it: target-peak back to auto', peak, 'auto')
end)
