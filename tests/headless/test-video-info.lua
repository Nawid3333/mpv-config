-- video-info.lua: every video announces itself as a small banner when its
-- real resolution is known (title = the size, detail = codec · pixel depth ·
-- source), one banner for every file, gone with its file, and no banner for
-- songs - their "video" is cover art, which gets no banner with or without
-- one. What a banner LOOKS like is notify.lua's, already covered there.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function card(id)
	for _, c in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		if c.id == id then
			return c
		end
	end
end

local function field(id, name)
	return function()
		local c = card(id)
		return c and c[name]
	end
end

local function ids()
	local list = {}
	for _, c in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		list[#list + 1] = c.id
	end
	return table.concat(list, ',')
end

local function video_size()
	local p = mp.get_property_native('video-params')
	return p and p.dw and (p.dw .. 'x' .. p.dh) or nil
end

H.run(function()
	-- The file the runner opened is already playing: its banner showed when
	-- video-params arrived and still stands.
	H.expect('a video announces itself as a banner', field('video-info', 'title'), video_size())
	H.eq('... at the real decoded size', field('video-info', 'title')(), '320x180')
	H.expect('... with codec, depth and source', field('video-info', 'detail'), 'H.264 · 8-bit · local file')

	-- 10-bit hevc, the common anime case: the depth is named, the codec too.
	local ten = H.media_path('tenbit/clip.mkv')
	H.load(ten)
	H.expect('10-bit: the depth is named', field('video-info', 'title'), video_size())
	H.expect('... HEVC, 10-bit, local file', field('video-info', 'detail'), 'HEVC · 10-bit · local file')
	H.expect('... at the size the decoder says', field('video-info', 'title'), '320x180')

	-- One banner id for every file: the next replaces the last one.
	H.load(H.media_path('plain/clip.mkv'))
	H.expect('the next video replaces the banner', field('video-info', 'title'), video_size())
	H.eq('one video-info banner, not one per file', ids(), 'video-info')

	-- Songs, with and without cover art: no banner, and their file change still
	-- removed the previous one (a song shows nothing; the next video does).
	H.load(H.media_path('music-tagged/Nova Lane - Paper Lanterns.mp3'))
	H.expect('a song: no banner', function()
		return card('video-info') == nil
	end, true)
	H.load(H.media_path('music-untagged/01 - Artist Name - Song Title (ft. Guest).flac'))
	H.expect('a song without cover art: none either', function()
		return card('video-info') == nil
	end, true)

	-- FastStream files announce like any other (the fragment stands in for the
	-- URL the host appends it to, the same string in `path` either way).
	H.load(H.media_path('fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'))
	H.expect('a FastStream file announces', field('video-info', 'title'), video_size())
	H.expect('... naming its source', field('video-info', 'detail'), 'H.264 · 8-bit · FastStream')
	-- gpu-toggles shows its own "Shaders" banner when the stream auto-applies
	-- Anime; wait it out so the check below sees only the video-info banner.
	H.sleep(2.2)
	H.eq('still one banner', ids(), 'video-info')

	-- "fs-content=" only in a query is no FastStream tag (FastStream #155; review,
	-- 2026-10-09: video-info matched it anywhere in the address)
	H.load(H.media_path('fs-forged-query/ep&x=fs-content=anime.mkv'))
	H.expect(
		'a query holding fs-content= is a local file, not FastStream',
		field('video-info', 'detail'),
		'H.264 · 8-bit · local file'
	)
end)
