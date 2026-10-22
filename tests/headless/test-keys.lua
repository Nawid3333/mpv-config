-- Keyboard bindings from input.conf that are plain mpv commands: seek keys,
-- volume keys/wheel, mute, fine speed, FastStream's episode keys, the basic and media keys,
-- and mpv's own keys switched off. Pressed with mpv's own `keypress`, so
-- they go through input.conf exactly like a real key. Needs a >= 180 s clip.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function seek_to(t)
	local done = H.expect_event('playback-restart')
	mp.commandv('seek', tostring(t), 'absolute', 'exact')
	done(5)
end

-- Presses a key and waits for the seek it causes to finish.
local function seek_key(key)
	local done = H.expect_event('playback-restart')
	mp.commandv('keypress', key)
	done(5)
	H.sleep(0.1)
	return mp.get_property_number('time-pos')
end

H.run(function()
	mp.set_property_native('pause', true)
	local duration = mp.get_property_number('duration')
	if not H.check('clip is long enough for the 60 s seeks', duration and duration >= 170, tostring(duration)) then
		return
	end

	-- key, start, expected position, tolerance: every seek key is an instant
	-- keyframe seek (2026-10-09), landing on the 1 s GOP of the generated clip
	local cases = {
		{ 'x', 60, 120, 1.5 },
		{ 'z', 120, 60, 1.5 },
		{ 'k', 60, 70, 1.5 },
		{ 'j', 70, 60, 1.5 },
		{ 'RIGHT', 60, 65, 1.5 },
		{ 'LEFT', 65, 60, 1.5 },
		{ '5', 10, duration * 0.5, 1.5 },
		{ '9', 10, duration * 0.9, 1.5 },
		{ '0', 100, 0, 1.5 },
	}
	for _, c in ipairs(cases) do
		seek_to(c[2])
		H.eq(string.format('key %s seeks %g -> %g', c[1], c[2], c[3]), seek_key(c[1]), c[3], c[4])
	end

	mp.set_property_number('volume', 50)
	local volume_cases = {
		{ 'UP', 60 },
		{ 'DOWN', 50 },
		{ 'DOWN', 40 },
		{ 'WHEEL_UP', 42 },
		{ 'WHEEL_DOWN', 40 },
	}
	for _, c in ipairs(volume_cases) do
		H.key(c[1])
		H.expect('key ' .. c[1] .. ' sets volume ' .. c[2], function()
			return mp.get_property_number('volume')
		end, c[2], 0.01)
	end

	local mute = mp.get_property_native('mute')
	H.key('m')
	H.expect('m toggles mute', function()
		return mp.get_property_native('mute')
	end, not mute)
	H.key('m')

	-- mpv's own keys are off (mpv.conf input-default-bindings=no): keys input.conf does not
	-- bind do nothing.
	H.eq('input-default-bindings is off', mp.get_property_native('input-default-bindings'), false)
	local sub_pos, sub_scale = mp.get_property_number('sub-pos'), mp.get_property_number('sub-scale')
	local audio_delay, subs = mp.get_property_number('audio-delay'), mp.get_property_native('sub-visibility')
	local window_scale, hwdec = mp.get_property_number('window-scale'), mp.get_property('hwdec')
	mp.set_property_number('speed', 2)
	local ass_override = mp.get_property('sub-ass-override')
	for _, key in ipairs({ 'BS', ']', '}', 'Ctrl++', 'p', 'v', 'u', 'Alt+1', 'Ctrl+h' }) do
		H.key(key)
	end
	H.sleep(0.3)
	H.eq('BS, ] and } are unbound (were speed keys)', mp.get_property_number('speed'), 2)
	H.eq('Ctrl++ is unbound (was audio delay)', mp.get_property_number('audio-delay'), audio_delay)
	H.eq('p is unbound (was pause; Space pauses)', mp.get_property_native('pause'), true)
	H.eq('v is unbound (was subtitles on/off; c does it)', mp.get_property_native('sub-visibility'), subs)
	H.eq('Alt+1 is unbound (was window size)', mp.get_property_number('window-scale'), window_scale)
	H.eq('Ctrl+h is unbound (was hwdec no/auto)', mp.get_property('hwdec'), hwdec)
	H.eq('u is unbound (was the subtitle style override)', mp.get_property('sub-ass-override'), ass_override)
	H.eq(
		'... and none of them moved or sized the subtitles',
		mp.get_property_number('sub-pos') + mp.get_property_number('sub-scale'),
		sub_pos + sub_scale
	)

	-- Caps Lock + q (the 3x key) arrives as Q, which was mpv's quit-and-save: unbound now, as
	-- are the capitals of the other letter keys (a Q that quits ends this test here)
	for _, key in ipairs({ 'Q', 'R', 'G', 'W', 'Z', 'X' }) do
		H.key(key)
	end
	H.sleep(0.3)
	H.eq('Q, R, G, W, Z, X are unbound (Caps Lock + q does not quit)', mp.get_property_number('speed'), 2)

	mp.set_property_number('speed', 1)
	H.key('d')
	H.expect('d adds 0.1 speed', function()
		return mp.get_property_number('speed')
	end, 1.1, 0.001)
	H.key('s')
	H.key('s')
	H.expect('s subtracts 0.1 speed', function()
		return mp.get_property_number('speed')
	end, 0.9, 0.001)

	-- the episode keys: the messages the FastStream helper hears for the next and the
	-- previous episode (faststream-episodes.lua plays the playlist's neighbour without
	-- one). A script message goes to every client, this script too.
	local heard = {}
	mp.register_script_message('faststream-next', function()
		heard[#heard + 1] = 'next'
	end)
	mp.register_script_message('faststream-previous', function()
		heard[#heard + 1] = 'previous'
	end)
	for _, key in ipairs({ 'n', 'N', 'P', 'NEXT', 'PREV' }) do
		H.key(key)
	end
	H.expect('n, Shift+N and media Next send faststream-next; Shift+P and media Previous -previous', function()
		return table.concat(heard, ' ')
	end, 'next next previous next previous')

	-- The basic keys input.conf binds itself, mpv's own being off. (The quit keys and the
	-- window's close button would end this test: the static tier checks their lines.)
	H.key('f')
	H.expect('f goes fullscreen', function()
		return mp.get_property_native('fullscreen')
	end, true)
	H.key('ESC')
	H.expect('Esc leaves fullscreen', function()
		return mp.get_property_native('fullscreen')
	end, false)
	local pauses = 0
	mp.register_script_message('faststream-pause', function()
		pauses = pauses + 1
	end)
	mp.set_property_native('pause', true)
	H.key('PLAYPAUSE')
	H.expect('media Play/Pause plays', function()
		return mp.get_property_native('pause')
	end, false)
	H.key('PAUSEONLY')
	H.expect('media Pause pauses', function()
		return mp.get_property_native('pause')
	end, true)
	H.expect('... and both tell the FastStream helper, as Space does', function()
		return pauses
	end, 2)

	mute = mp.get_property_native('mute')
	H.key('MUTE')
	H.expect('media Mute toggles mute', function()
		return mp.get_property_native('mute')
	end, not mute)
	H.key('MUTE')
	mp.set_property_number('volume', 50)
	H.key('VOLUME_UP')
	H.expect('media Volume up adds 2', function()
		return mp.get_property_number('volume')
	end, 52, 0.01)
	H.key('VOLUME_DOWN')
	H.expect('media Volume down takes 2', function()
		return mp.get_property_number('volume')
	end, 50, 0.01)

	seek_to(60)
	H.eq('media Forward seeks 60 -> 120', seek_key('FORWARD'), 120, 1.5)
	H.eq('media Rewind seeks 120 -> 60', seek_key('REWIND'), 60, 1.5)
end)
