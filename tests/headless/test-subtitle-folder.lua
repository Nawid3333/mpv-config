-- mpv.conf's sub-file-paths: a subtitle in a sub\ (or subtitles\) folder next
-- to the video is loaded with it. The list was written with ':' between the
-- folders, the Unix separator; mpv splits path lists on ';' on Windows, so the
-- one folder it looked in was "sub:subtitles", and none was ever found
-- (2026-10-10 review).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	local found
	for _, t in ipairs(mp.get_property_native('track-list') or {}) do
		if t.type == 'sub' and t['external-filename'] then
			found = t['external-filename']
		end
	end
	H.check(
		'the subtitle in the sub folder next to the video is loaded',
		found ~= nil and found:find('[/\\]sub[/\\]movie%.srt$') ~= nil,
		tostring(found)
	)
end)
