-- subtitle-toggle.lua (key c): selects the first sub track when none is
-- active, otherwise flips visibility; with no sub track at all it loads a
-- matching subtitle file from the video's folder. Also checks mpv.conf's
-- sub-auto=fuzzy picked up the .srt next to the video.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function first_sub()
	for _, t in ipairs(mp.get_property_native('track-list') or {}) do
		if t.type == 'sub' then
			return t
		end
	end
end

H.run(function()
	local track = first_sub()
	if not H.check('sub-auto loaded the .srt next to the video', track ~= nil) then
		return
	end

	mp.set_property('sid', 'no')
	H.sleep(0.1)
	H.key('c')
	H.expect('c with no track selected selects the first sub track', function()
		return mp.get_property_number('sid')
	end, track.id)
	H.expect('... and makes it visible', function()
		return mp.get_property_native('sub-visibility')
	end, true)
	H.key('c')
	H.expect('c again hides subtitles', function()
		return mp.get_property_native('sub-visibility')
	end, false)
	H.key('c')
	H.expect('c again shows them', function()
		return mp.get_property_native('sub-visibility')
	end, true)

	-- No sub track at all (auto-loading off): c finds the file itself. Subtitles were hidden
	-- on the file before, and sub-visibility stays off across files: c shows them as well.
	mp.set_property('sub-auto', 'no')
	H.key('c')
	H.expect('c hides subtitles before the next file', function()
		return mp.get_property_native('sub-visibility')
	end, false)
	H.load(mp.get_property('path'))
	H.check('reloaded without auto-loaded subs', first_sub() == nil)
	H.key('c', 0.4)
	local loaded = first_sub()
	H.check('c loads the subtitle file from the video folder', loaded ~= nil and loaded.selected == true)
	H.eq(
		'... and shows it, though subtitles were hidden on the file before',
		mp.get_property_native('sub-visibility'),
		true
	)
end)
