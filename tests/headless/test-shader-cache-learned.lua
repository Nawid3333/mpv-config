-- shader-cache (9/11): learned cases (Scripts/shader-cache/cases.lua). Phase 8
-- left a new display driver and two learned cases - a software-decoded 4:4:4
-- file with bt.601/sRGB full-range tags through Anime at 1.5x, and mpv's empty
-- window. The full warm-up this start runs replays both after the matrix: a
-- clip made in exactly that format, then the idle window. Then the old capture
-- log is imported: its real gaps ([cache fresh]/[cache done], both states of a
-- "(before: ...)" line) become cases, a [cache stale] line does not, and no
-- title reaches the file. Last, the menu's status banner. Leaves no learned
-- cases and a stamp with another display driver for phase 10.
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')
local utils = require('mp.utils')

local function card(id)
	for _, c in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		if c.id == id then
			return c
		end
	end
end

H.run(function()
	R.wait_playing(H)
	H.wait_until(function()
		return R.saw('warming')
	end, 5)
	H.eq('a new driver: a full warm-up', R.info.mode, 'full')
	H.eq('warm-up finished', R.wait_end(H, 90), 'done', R.info.summary)
	local summary = R.info.summary or ''
	H.check(
		'the learned cases are replayed after the matrix (8 + 2 steps)',
		summary:find('over 10 steps', 1, true),
		summary
	)
	local p = R.info.progress or {}
	H.check(
		'... and counted in the progress bar',
		p.total == 10 and p.done == 10,
		string.format('%s/%s', p.done, p.total)
	)
	local dir = utils.join_path(os.getenv('TEMP') or os.getenv('TMP') or '.', 'mpv-shader-warmup-v1')
	local clip = 'case-320x180-yuv444p-ffv1-bt.601-bt.601-625-srgb-full.mkv'
	H.check('... from a clip made in exactly that format', utils.file_info(utils.join_path(dir, clip)) ~= nil, clip)

	-- the log written before learning existed
	local log = mp.command_native({ 'expand-path', '~~state/shader-misses.log' })
	local f = assert(io.open(log, 'w'))
	f:write(
		'2026-09-27 20:01:02  +3  Secret Title | 1712x720 yuv420p hevc bt.709/bt.1886, decoder no'
			.. ' | Movie (SSimSuperRes), sharpen 0.5 | 2560x1440 fullscreen  [cache fresh]\n',
		'2026-09-27 20:05:00  +2  Other | Title | 1920x1080 nv12 h264 bt.709/bt.1886, decoder d3d11va-copy'
			.. ' | no upscaler | 1280x720 window  (before: Other | Title | 1920x1080 nv12 h264 bt.709/bt.1886,'
			.. ' decoder d3d11va-copy | no upscaler | 2560x1440 fullscreen)  [cache done]\n',
		'2026-09-27 20:06:00  +9  Old Title | 1280x720 vulkan/nv12 h264 bt.709/bt.1886, decoder vulkan'
			.. ' | Anime | 2560x1440 fullscreen  [cache stale]\n',
		'2026-09-27 20:07:00  +1  Empty Title | no video | no upscaler | 1280x720 window  [cache fresh]\n'
	)
	f:close()
	R.write_cases({})
	mp.commandv('script-message-to', 'shader_cache', 'import-log')
	H.expect('the old log is imported: its 4 real gaps (a stale line is not one)', function()
		return R.info.cases
	end, 4)
	local data = R.read_cases()
	local by = {}
	for _, c in ipairs(data.cases or {}) do
		by[c.idle and 'idle' or string.format('%sx%s %s', c.w, c.h, c.ratio)] = c
	end
	local movie = by['1712x720 1.5'] or {}
	H.eq('... the Movie line: chain and sharpness', (movie.chain or '?') .. ' ' .. tostring(movie.sharpen), 'movie 0.5')
	H.eq(
		'... its decoder and colours',
		(movie.hwdec or '?') .. ' ' .. (movie.matrix or '?') .. '/' .. (movie.gamma or '?'),
		'no bt.709/bt.1886'
	)
	H.check('... a window line: its own scale (0.67)', by['1920x1080 0.67'] ~= nil, R.cases_text())
	H.check('... and the state before it (fullscreen, 1.33)', by['1920x1080 1.33'] ~= nil, R.cases_text())
	H.check('... the empty window', by.idle ~= nil, R.cases_text())
	H.check('... no title in the file', not R.cases_text():find('Title', 1, true), R.cases_text())
	H.eq('... the newest gap is the newest line', data.last_gap, '2026-09-27 20:07:00')

	mp.commandv('script-message-to', 'shader_cache', 'status')
	H.expect('the menu entry shows a status banner', function()
		return (card('shader-cache') or {}).title
	end, 'Shader capture')
	local detail = (card('shader-cache') or {}).detail or ''
	H.check('... counting what was learned', detail:find('^4 learned'), detail)

	os.remove(log)
	R.write_cases({})
	R.write_stamp({ driver = '0.0.0.0-idle' })
end)
