-- subtitle-sync.lua (key t): the sync timeline. The clip's sound is a beep at
-- 2, 6, 10, 14 and 18 s and its .srt has one line on each beep, so opening the
-- panel must read all 5 lines AND find the 5 beeps at those times (the audio
-- is analysed by a second, windowless mpv). Then every way of shifting: keys,
-- the wheel on each row, dragging each row, clicking to jump, Esc/Enter/t -
-- and outside the panel a click still plays/pauses. Last, a track INSIDE the
-- clip: read in full with ffmpeg, or (no ffmpeg) collected as playback reads
-- it. What the panel LOOKS like needs a real window - checked by screenshot
-- when it was built.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function state()
	return mp.get_property_native('user-data/subtitle-sync') or {}
end

local function field(name)
	return function()
		return state()[name]
	end
end

local function prop(name)
	return function()
		return mp.get_property_number(name)
	end
end

local function row_y(name)
	local row = state().rows[name]
	return math.floor((row.y0 + row.y1) / 2)
end

-- window x of time t: the playhead (time-pos) is the panel's middle
local function x_at(t)
	local s = state()
	return math.floor(s.cx + (t - mp.get_property_number('time-pos')) * s.pps + 0.5)
end

-- press on a row, move dx px in 5 steps, release. The tool reads where the
-- press was when its handler runs, a moment after the press - a hand takes
-- longer than that to start moving, a test does not unless it waits (traced
-- 2026-09-27: without the wait the first step became the origin and 1/5 of
-- every drag went missing).
local function drag(row, dx)
	local y, x = row_y(row), state().cx - 150
	mp.commandv('mouse', tostring(x), tostring(y))
	mp.commandv('keydown', 'MBTN_LEFT')
	H.sleep(0.05)
	for i = 1, 5 do
		mp.commandv('mouse', tostring(x + math.floor(dx * i / 5)), tostring(y))
		H.sleep(0.03)
	end
	H.sleep(0.05)
	mp.commandv('keyup', 'MBTN_LEFT')
	H.sleep(0.35)
end

H.run(function()
	mp.set_property_native('pause', true)
	mp.set_property('sid', '1')
	mp.commandv('seek', '5', 'absolute+exact')
	H.sleep(0.3)
	local pos = mp.get_property_number('time-pos')

	H.key('t')
	H.expect('t opens the panel', field('open'), true)
	H.expect('the lines of the external .srt are read (5)', field('cues'), 5, nil, 5)
	H.eq('... every line, not only the ones shown', state().subs, 'ready')
	H.expect('the audio is analysed', function()
		return (state().bins or 0) >= 900
	end, true, nil, 15)
	-- the encoder puts the beeps 21 ms early; one value covers 20 ms
	local onsets = state().onsets or {}
	H.eq('the audio row finds the 5 beeps', #onsets, 5)
	for i = 1, 5 do
		H.eq(string.format('... beep %d at %d s', i, 4 * i - 2), onsets[i], 4 * i - 2, 0.06)
	end

	H.key('RIGHT')
	H.key('RIGHT')
	H.expect('Right: subtitles +0.05 s (twice)', prop('sub-delay'), 0.1, 0.001)
	H.eq('... and no seek', mp.get_property_number('time-pos'), pos, 0.05)
	H.key('Shift+RIGHT')
	H.expect('Shift+Right: audio +0.05 s', prop('audio-delay'), 0.05, 0.001)

	local x = state().cx + 100
	local volume = mp.get_property_number('volume')
	mp.commandv('mouse', tostring(x), tostring(row_y('subs')))
	H.key('WHEEL_UP')
	H.expect('wheel on the subtitle row: +0.05 s', prop('sub-delay'), 0.15, 0.001)
	mp.commandv('mouse', tostring(x), tostring(row_y('audio')))
	H.key('WHEEL_DOWN')
	H.expect('wheel on the audio row: -0.05 s', prop('audio-delay'), 0, 0.001)
	H.eq('... not the volume', mp.get_property_number('volume'), volume)
	mp.commandv('mouse', tostring(x), tostring(row_y('time')))
	H.key('WHEEL_UP')
	H.expect('wheel on the time row zooms in', field('view'), 24, 0.01)
	H.key('WHEEL_DOWN')
	H.expect('... and out again', field('view'), 30, 0.01)

	local pps = state().pps
	drag('subs', math.floor(pps + 0.5))
	H.expect('dragging the subtitle row 1 s to the right: +1 s', prop('sub-delay'), 1.15, 0.03)
	H.eq('... seeks nowhere', mp.get_property_number('time-pos'), pos, 0.05)
	H.eq('... and does not play', mp.get_property_native('pause'), true)
	drag('audio', -math.floor(pps / 2 + 0.5))
	H.expect('dragging the audio row 0.5 s to the left: -0.5 s', prop('audio-delay'), -0.5, 0.03)
	drag('time', -math.floor(2 * pps + 0.5))
	H.expect('dragging the time row 2 s to the left scrubs 2 s on', prop('time-pos'), pos + 2, 0.1)
	H.eq('... and it stays paused, as it was', mp.get_property_native('pause'), true)

	local delay = mp.get_property_number('sub-delay')
	H.click(x_at(10 + delay + 0.25), row_y('subs'))
	H.expect('a click on a subtitle line jumps to its start', prop('time-pos'), 10 + delay, 0.06)
	H.click(x_at(8), row_y('time'))
	H.expect('a click on the time row jumps there', prop('time-pos'), 8, 0.06)
	H.eq('a click in the panel does not play/pause', mp.get_property_native('pause'), true)
	H.click(200, 60)
	H.eq('a click outside the panel still plays/pauses', mp.get_property_native('pause'), false)
	mp.set_property_native('pause', true)

	H.key('ESC')
	H.expect('Esc closes it', field('open'), false)
	H.eq('... with the subtitle delay put back', mp.get_property_number('sub-delay'), 0, 0.001)
	H.eq('... and the audio delay', mp.get_property_number('audio-delay'), 0, 0.001)
	pos = mp.get_property_number('time-pos')
	local done = H.expect_event('playback-restart')
	mp.commandv('keypress', 'RIGHT')
	done(5)
	-- a keyframe seek (instant, 2026-10-09): the first keyframe at or after +5 s,
	-- within the clip's keyframe spacing
	local landed = mp.get_property_number('time-pos') - pos
	H.check('closed: Right seeks again (+5 s, to the next keyframe)', landed >= 4.9 and landed <= 7.1, landed)
	mp.set_property_native('pause', true)

	H.key('t')
	H.key('LEFT')
	H.key('Shift+LEFT')
	H.key('ENTER')
	H.expect('Enter keeps the subtitle delay', prop('sub-delay'), -0.05, 0.001)
	H.eq('... and the audio delay', mp.get_property_number('audio-delay'), -0.05, 0.001)
	H.key('t')
	H.key('RIGHT')
	H.key('t')
	H.expect('t again closes and keeps it too', prop('sub-delay'), 0, 0.001)
	mp.set_property_number('audio-delay', 0)

	-- a track inside the clip (made with ffmpeg by run-tests.ps1, if it has one)
	local embedded = H.media_path('sync-embedded/talk.mkv')
	local f = io.open(embedded, 'rb')
	if not f then
		H.info('no ffmpeg where the media was made: the embedded-track checks are skipped')
		return
	end
	f:close()
	H.load(embedded)
	mp.set_property_native('pause', true)
	mp.set_property('sid', '1')
	H.key('t')
	if state().ffmpeg or H.wait_until(field('ffmpeg'), 5) then
		H.expect('a track inside the file: all 5 lines, read with ffmpeg', field('cues'), 5, nil, 10)
		H.eq('... in full', state().subs, 'ready')
	else
		H.info('no ffmpeg for mpv: the ffmpeg read is skipped')
	end
	H.key('t')

	-- without ffmpeg: the lines collected as playback reads them, kept over a seek
	mp.commandv('change-list', 'script-opts', 'append', 'subtitle_sync-ffmpeg=C:/nonexistent/ffmpeg.exe')
	H.load(embedded)
	mp.set_property('sid', '1')
	H.key('t')
	H.expect('no ffmpeg: the lines are collected as they are read', field('subs'), 'live')
	mp.set_property_native('pause', false)
	H.expect('... the first lines arrive while it plays', function()
		return (state().cues or 0) >= 1
	end, true, nil, 8)
	mp.set_property_native('pause', true)
	H.eq('... from the start of the clip', state().first_cue, 2)
	local seen = state().cues
	mp.commandv('seek', '15', 'absolute+exact')
	H.sleep(1) -- mpv drops its older lines on a seek; the tool collects every 0.5 s
	H.check(
		'... and a seek loses none of them',
		(state().cues or 0) >= seen,
		'had ' .. seen .. ', now ' .. tostring(state().cues)
	)
	H.eq('... while the early ones stay', state().first_cue, 2)
	H.key('t')
end)
