-- faststream-private.lua: a private window's temp files go once mpv has moved on from the stream, gone idle or
-- closed, and nothing else does. The runner writes them anew each run under fs-private-files/: private packages
-- (tst101, tst102, tst105: folder faststream-mpv-hls-p-*, fs-private=1 in target.txt; tst106 without a playlist,
-- so it fails to open), an ordinary window's (tst103), a folder named private whose target is not (tst104),
-- private subtitle folders (tst201, tst202, tst205, tst206) and an ordinary window's (tst203). Phase move-on ends
-- with mpv closing on tst102; phase after-quit looks at what that left.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local root = H.media .. '/fs-private-files/'
local SRT = '1 English.srt'

local function exists(rel)
	return utils.file_info(root .. rel) ~= nil
end

local function package_there(dir)
	return exists(dir .. '/0.m3u8') or exists(dir .. '/target.txt')
end

-- The script runs in a thread of its own: each check waits until it has handled what came before.
local function passes()
	return mp.get_property_native('user-data/faststream-private/passes') or 0
end

local function handled(before)
	return H.wait_until(function()
		return passes() > before
	end, 5)
end

-- Loads <rel> (under fs-private-files/, or the media folder's plain clip) with <subtitle> as its sub-files, as
-- the helper hands a stream over, and waits until it plays and the script has handled it.
local function load(rel, subtitle)
	local before = passes()
	local restarted = H.expect_event('playback-restart')
	local path = rel:find('^plain/') and H.media_path(rel) or (root .. rel)
	local options = subtitle and ('sub-files=' .. root .. subtitle) or ''
	mp.commandv('loadfile', path, 'replace', '-1', options)
	return restarted(15) and handled(before)
end

local function external_subtitles()
	local n = 0
	for _, track in ipairs(mp.get_property_native('track-list') or {}) do
		if track.type == 'sub' and track.external then
			n = n + 1
		end
	end
	return n
end

H.run(function()
	if os.getenv('MPV_TEST_PHASE') == 'after-quit' then
		H.eq('mpv closed on a private package: its files are gone', package_there('faststream-mpv-hls-p-tst102'), false)
		H.eq('... and its subtitles', exists('faststream-mpv-subs-p-tst202/' .. SRT), false)
		return
	end

	H.check(
		'a private package loads with its subtitles',
		load('faststream-mpv-hls-p-tst101/0.m3u8', 'faststream-mpv-subs-p-tst201/' .. SRT)
	)
	H.eq('... its subtitle track', external_subtitles(), 1)
	H.eq('while it plays, its files stay', package_there('faststream-mpv-hls-p-tst101'), true)
	H.eq('... and its subtitles', exists('faststream-mpv-subs-p-tst201/' .. SRT), true)

	-- a quality switch takes the subtitle files along to the next file
	H.check('the next file with the same subtitles', load('plain/clip.mkv', 'faststream-mpv-subs-p-tst201/' .. SRT))
	H.eq('moved on: the private package is gone', package_there('faststream-mpv-hls-p-tst101'), false)
	H.eq('... the subtitles stay, as the file playing has them', exists('faststream-mpv-subs-p-tst201/' .. SRT), true)
	H.check('a file without them', load('plain/clip.mkv'))
	H.eq('... now the subtitles are gone', exists('faststream-mpv-subs-p-tst201/' .. SRT), false)

	-- an ordinary window's, and a folder named private whose target is not
	H.check(
		"an ordinary window's package",
		load('faststream-mpv-hls-tst103/0.m3u8', 'faststream-mpv-subs-tst203/' .. SRT)
	)
	H.check('a folder named private, its target not', load('faststream-mpv-hls-p-tst104/0.m3u8'))
	H.check('and a local file', load('plain/clip.mkv'))
	H.eq(
		"an ordinary window's package stays",
		exists('faststream-mpv-hls-tst103/0.m3u8') and exists('faststream-mpv-hls-tst103/target.txt'),
		true
	)
	H.eq('... and its subtitles', exists('faststream-mpv-subs-tst203/' .. SRT), true)
	H.eq(
		'the folder named private, its target not, stays',
		exists('faststream-mpv-hls-p-tst104/0.m3u8') and exists('faststream-mpv-hls-p-tst104/target.txt'),
		true
	)

	-- a private package mpv cannot open: its subtitles never become a track, and mpv idles (idle=yes)
	local before = passes()
	mp.commandv(
		'loadfile',
		root .. 'faststream-mpv-hls-p-tst106/0.m3u8',
		'replace',
		'-1',
		'sub-files=' .. root .. 'faststream-mpv-subs-p-tst206/' .. SRT
	)
	H.check('a private package that fails to open', handled(before))
	H.eq('... its files are gone', exists('faststream-mpv-hls-p-tst106/target.txt'), false)
	H.eq('... and its subtitles', exists('faststream-mpv-subs-p-tst206/' .. SRT), false)

	-- nothing plays any more
	H.check('a private package', load('faststream-mpv-hls-p-tst105/0.m3u8', 'faststream-mpv-subs-p-tst205/' .. SRT))
	before = passes()
	mp.commandv('stop')
	H.check('stopped', handled(before))
	H.eq('... its files are gone', package_there('faststream-mpv-hls-p-tst105'), false)
	H.eq('... and its subtitles', exists('faststream-mpv-subs-p-tst205/' .. SRT), false)

	-- mpv closes while a private package plays: phase after-quit looks
	H.check(
		'the last private package',
		load('faststream-mpv-hls-p-tst102/0.m3u8', 'faststream-mpv-subs-p-tst202/' .. SRT)
	)
	H.eq('... its subtitle track', external_subtitles(), 1)
end)
