-- stream-resume.lua, process 2 of 2 (see test-stream-resume-save.lua). The
-- runner opens the SAME episode under a different file name (a new CDN token
-- in real life) but the same fs-id - that is what resume keys on.
--
-- One entry per fs-id (= per page URL): whatever was played last under that
-- id owns the entry, so the duration-mismatch case runs last.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local EPISODE = 'fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'
-- The same episode with an fs-id BEFORE the fragment (a query parameter in real life).
local QUERY_ID = 'fs-query/ep&fs-id=cccccccccccccccc#fs-content=anime.mkv'

local function seek(t)
	local done = H.expect_event('playback-restart')
	mp.commandv('seek', tostring(t), 'absolute', 'exact')
	done(5)
	H.sleep(0.5)
end

-- The resume note: a notify.lua banner (nil when none is showing).
local function note()
	for _, c in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		if c.id == 'resume' then
			return c.title .. ' / ' .. c.detail
		end
	end
end

local function pos()
	return mp.get_property_number('time-pos', 999)
end

H.run(function()
	H.eq('fresh process resumes the episode at 0:40', pos(), 40, 1.5)
	H.expect('the resume note is a small banner', note, 'Resumed at 0:40 / Home: start from the beginning')

	H.load(H.media_path('plain/clip.mkv'))
	H.eq('the note goes with its file', note(), nil)
	H.check('a local file is never resumed', pos() < 2, pos())

	H.load(H.media_path(EPISODE))
	H.eq('the episode resumes again after another file', pos(), 40, 2)

	-- A start given with the file (FastStream's player button hands over where the
	-- browser's player was, as the per-file option start) wins over the saved 0:40.
	H.load(H.media_path('plain/clip.mkv'))
	local restarted = H.expect_event('playback-restart')
	mp.commandv('loadfile', H.media_path(EPISODE), 'replace', '-1', 'start=25')
	restarted(15)
	H.eq('a start given with the file wins over the saved position', pos(), 25, 2)
	H.eq('and no resume note says otherwise', note(), nil)
	-- It is still saved from there: the next plain open resumes at 0:25's point.
	seek(40)
	H.load(H.media_path('plain/clip.mkv'))
	H.load(H.media_path(EPISODE))
	H.eq('the position is still saved after a given start', pos(), 40, 2)

	-- An fs-id outside the fragment (a query parameter in a real URL; before the
	-- '#' in this file name) is no resume key: only the host's own fragment item is.
	H.load(H.media_path(QUERY_ID))
	seek(40)
	H.load(H.media_path('plain/clip.mkv'))
	H.load(H.media_path(QUERY_ID))
	H.check('an fs-id before the fragment is not resumed', pos() < 2, pos())
	H.load(H.media_path(EPISODE))

	-- Finishing it (the last 8 %, at least 30 s) forgets it.
	seek(100)
	H.load(H.media_path('plain/clip.mkv'))
	H.load(H.media_path(EPISODE))
	H.check('a finished episode starts from the beginning', pos() < 2, pos())

	-- Same fs-id, different duration: another video under the same page URL
	-- must not jump to this episode's position.
	seek(40)
	H.load(H.media_path('plain/clip.mkv'))
	H.load(H.media_path('fs-mismatch/other#fs-content=movie&fs-id=a1b2c3d4e5f60718.mkv'))
	H.check('same fs-id with another duration is not resumed', pos() < 2, pos())
end)
