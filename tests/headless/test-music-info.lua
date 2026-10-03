-- music-info.lua: for songs, the window title reads "Artist – Title (feat. X)"
-- and the details are read from the tags, or from the file name when there are
-- none; the panel shows only while uosc's bottom bar does (stood in for here by
-- user-data/uosc/bottom-ui, which uosc publishes - a headless uosc has no
-- display and never does), and always without cover art. A video without an
-- artist tag is left alone. What the panel LOOKS like needs a real window -
-- checked by screenshot when it was built.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function info(key)
	return function()
		return (mp.get_property_native('user-data/music-info') or {})[key]
	end
end

local function bottom_ui(visibility)
	mp.set_property_native(
		'user-data/uosc/bottom-ui',
		{ visibility = visibility, controls_top = 600, timeline_top = 660, height = 720 }
	)
end

H.run(function()
	-- tagged mp3, cover.jpg next to it: artist tag "Nova Lane feat. Test Artist"
	H.expect('tagged: window title "Artist – Title (feat. X)"', function()
		return mp.get_property('title')
	end, 'Nova Lane – Paper Lanterns (feat. Test Artist) - mpv')
	H.eq('tagged: artist without the feat.', info('artist')(), 'Nova Lane')
	H.eq('tagged: featured artist on its own', info('featured')(), 'Test Artist')
	H.eq('tagged: title', info('title')(), 'Paper Lanterns')
	H.eq('tagged: album, year, track, genre', info('details')(), 'Night Signals · 2019 · Track 3 of 11 · Synthpop')
	H.eq('tagged: the audio format line', info('format')(), 'MP3 · 44.1 kHz · Mono · 64 kbps')
	H.eq('cover.jpg counts as cover art', info('cover')(), true)
	H.eq('with cover art: hidden while uosc bar is hidden', info('visibility')(), 0)
	bottom_ui(1)
	H.expect('... shows when uosc bar shows', info('visibility'), 1)
	bottom_ui(0.5)
	H.expect('... fades with it', info('visibility'), 0.5)
	bottom_ui(0)
	H.expect('... and hides with it', info('visibility'), 0)

	-- no tags: "01 - Artist Name - Song Title (ft. Guest).flac", a second song after it
	H.load(H.media_path('music-untagged/01 - Artist Name - Song Title (ft. Guest).flac'))
	H.expect('untagged: artist and title from the file name', function()
		return mp.get_property('title')
	end, 'Artist Name – Song Title (feat. Guest) - mpv')
	H.eq(
		'untagged: track number dropped, feat. split off',
		tostring(info('artist')()) .. ' / ' .. tostring(info('featured')()),
		'Artist Name / Guest'
	)
	H.eq('without cover art the panel stays', info('visibility')(), 1)
	H.expect('up next: the following song, from its file name', info('next'), 'Other Artist – Next Song')

	-- feat. inside the title, two ARTIST values
	H.load(H.media_path('music-feat/harbor-lights.mp3'))
	H.expect('feat. in the title: moved out, the rest kept', info('title'), 'Harbor Lights [Live]')
	H.eq('... featured', info('featured')(), 'Juno Vale')
	H.eq('several artists joined', info('artist')(), 'Nova Lane, Echo Harbor')

	-- a video without an artist tag: untouched
	H.load(H.media_path('plain/clip.mkv'))
	H.expect("a plain video keeps mpv's own title", function()
		return mp.get_property('title')
	end, '${?media-title:${media-title}}${!media-title:No file} - mpv')
	H.eq('... and gets no music info', info('title')(), nil)
end)
