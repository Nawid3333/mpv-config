-- autoload.lua with script-opts/autoload.conf same_type=yes: opening a video
-- queues the other videos in its folder, never the audio file next to them.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	H.wait_until(function()
		return mp.get_property_number('playlist-count', 0) >= 2
	end, 3)
	local names = {}
	for _, e in ipairs(mp.get_property_native('playlist') or {}) do
		names[#names + 1] = e.filename:match('[^/\\]+$')
	end
	H.eq("the folder's two videos are queued", mp.get_property_number('playlist-count'), 2)
	H.check(
		'the audio file is not queued',
		not table.concat(names, ','):find('song', 1, true),
		table.concat(names, ', ')
	)
end)
