-- A skip to the end ends the file: FastStream's autoplay goes on at an end (eof-reached,
-- keep-open), so a skip past the end, or into its last second, has to arrive there - and
-- from a pause too: playback goes on to the end, where keep-open pauses again.
-- Two processes (tests/run-tests.ps1, "skip-to-end"):
--   keys     - hls-long/long.m3u8 (one 180 s MPEG-TS segment) read only ~1.5 s ahead
--              (demuxer-max-bytes 128 KiB, set after stream-buffer.lua's own), paused: x,
--              k, Right and the media Forward key, each from a spot whose end is not
--              buffered (drop-buffers first: an earlier case's end stays in the buffer).
--              mpv's own `seek <n>` past the end asks the demuxer, which FFmpeg's HLS
--              demuxer refuses, and mpv went on from the end of the buffer: no end
--              (skip-forward.lua). A skip that stays inside the file is the keyframe
--              seek it was.
--   timeline - plain/clip.mkv on an OSD surface (--vo=sixel), paused: a click on the
--              timeline's last pixel ends the file (a keyframe seek stopped short of the
--              end); a click in the middle stays a keyframe seek (uosc Timeline.lua, a
--              local change).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local PHASE = os.getenv('MPV_TEST_PHASE') or 'keys'

if PHASE == 'keys' then
	-- after stream-buffer.lua's on_load (priority 50), which sets the file's limits
	mp.add_hook('on_load', 60, function()
		mp.set_property('file-local-options/demuxer-max-bytes', '128KiB')
	end)
end

local function cache()
	return mp.get_property_native('demuxer-cache-state') or {}
end

local function eof()
	return mp.get_property_native('eof-reached')
end

local function paused()
	return mp.get_property_native('pause')
end

local function skip()
	return mp.get_property_native('user-data/skip-forward') or {}
end

-- An exact seek there, paused, and settled: away from the end again.
local function seek_to(t)
	local done = H.expect_event('playback-restart')
	mp.commandv('seek', string.format('%.3f', t), 'absolute+exact')
	H.check('seek to ' .. t .. ' done', done(10))
	H.expect('not at the end at ' .. t, eof, false)
end

-- Presses a skip key from `from`, with the end not buffered, and checks that it ends the file.
local function ends(key, from, duration)
	mp.commandv('drop-buffers')
	seek_to(from)
	H.sleep(0.5)
	H.eq(string.format('%s from %g: the end is not buffered', key, from), cache()['eof-cached'], false)
	local skips = skip().skips or 0
	mp.commandv('keypress', key)
	H.expect(string.format('%s from %g: the file ends', key, from), eof, true, nil, 10)
	H.eq('... at its end', mp.get_property_number('time-pos'), duration, 0.5)
	H.eq('... skip-forward went to the end', skip().to_end, true)
	H.eq('... one skip', skip().skips, skips + 1)
	H.expect('... paused there (keep-open)', paused, true)
end

H.run(function()
	mp.set_property_native('pause', true)
	local duration = mp.get_property_number('duration') or 0

	if PHASE == 'keys' then
		H.check(
			'a 180 s HLS stream',
			mp.get_property('file-format') == 'hls' and duration > 170,
			tostring(mp.get_property('file-format')) .. ' ' .. duration
		)
		ends('x', 150, duration)
		ends('k', duration - 8, duration)
		-- 5 s from 5.5 s before the end: it would land in the last second
		ends('RIGHT', duration - 5.5, duration)
		ends('FORWARD', duration - 40, duration)
		-- a skip inside the file is mpv's keyframe seek, as before (the clip's keyframes
		-- are 1 s apart)
		seek_to(100)
		local done = H.expect_event('playback-restart')
		mp.commandv('keypress', 'k')
		H.check('k from 100 seeks', done(10))
		H.eq('... to 110', mp.get_property_number('time-pos'), 110, 1.5)
		H.eq('... as a skip, not to the end', skip().to_end, false)
		H.eq('... not at the end', eof(), false)
		H.eq('... still paused', paused(), true)
		return
	end

	-- timeline
	local function bottom()
		return mp.get_property_native('user-data/uosc/bottom-ui')
	end
	if
		not H.check(
			'uosc lays out its bottom bar (user-data/uosc/bottom-ui)',
			H.wait_until(function()
				return bottom() ~= nil
			end, 5),
			'no bottom-ui published: no OSD surface (the runner passes --vo=sixel)'
		)
	then
		return
	end
	local width = (mp.get_property_native('osd-dimensions') or {}).w or 0
	local b = bottom()
	local y = math.floor((b.timeline_top + b.height) / 2)
	H.check(
		'the timeline lies inside the surface',
		width > 100 and b.timeline_top < b.height,
		width .. ' ' .. b.timeline_top
	)
	-- the pointer moved over the timeline shows it (uosc draws its zones only when
	-- visible, and hides the bar after a while under a resting pointer); a move is to
	-- another pixel (the same one is no move to uosc)
	local moves = 0
	local function show_bar()
		moves = moves + 1
		mp.commandv('mouse', tostring(math.floor(width / 2) + moves), tostring(y))
		H.expect('the bar shows with the pointer on it', function()
			return (bottom() or {}).visibility
		end, 1, nil, 3)
	end

	-- a click where the pointer already is: uosc reads the pointer's position from a
	-- property it observes, and a press sent with the move came at the old position
	local function click_at(x)
		mp.commandv('mouse', tostring(x), tostring(y))
		H.sleep(0.3)
		mp.commandv('keydown', 'MBTN_LEFT')
		H.sleep(0.05)
		mp.commandv('keyup', 'MBTN_LEFT')
		H.sleep(0.35)
	end

	seek_to(5)
	show_bar()
	click_at(width - 1)
	H.expect('a click on the last pixel ends the file', eof, true, nil, 5)
	H.eq('... at its end', mp.get_property_number('time-pos'), duration, 0.5)
	H.expect('... paused there (keep-open)', paused, true)

	seek_to(5)
	show_bar()
	local done = H.expect_event('playback-restart')
	click_at(math.floor(width / 2))
	H.check('a click in the middle seeks', done(5))
	H.eq('... there, by keyframe', mp.get_property_number('time-pos'), duration / 2, 1.5)
	H.eq('... not to the end', eof(), false)
	H.eq('... still paused', paused(), true)
end)
