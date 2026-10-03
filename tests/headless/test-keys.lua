-- Keyboard bindings from input.conf that are plain mpv commands: seek keys,
-- volume keys/wheel, mute, fine speed. Pressed with mpv's own `keypress`, so
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

	-- key, start, expected position, tolerance (keyframe seeks land on the
	-- 1 s GOP of the generated clip; `exact` ones land on the frame)
	local cases = {
		{ 'x', 60, 120, 1.5 },
		{ 'z', 120, 60, 1.5 },
		{ 'k', 60, 70, 0.1 },
		{ 'j', 70, 60, 0.1 },
		{ 'RIGHT', 60, 65, 0.1 },
		{ 'LEFT', 65, 60, 0.1 },
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
	H.check('m toggles mute', mp.get_property_native('mute') ~= mute)
	H.key('m')

	-- Keys this config deliberately unbinds (mpv defaults they replaced).
	local sub_delay, sub_pos = mp.get_property_number('sub-delay'), mp.get_property_number('sub-pos')
	local panscan = mp.get_property_number('panscan')
	mp.set_property_number('speed', 2)
	H.key('Z')
	H.key('R')
	H.key('W')
	H.key('BS')
	H.eq('Z is unbound (was sub-delay +0.1)', mp.get_property_number('sub-delay'), sub_delay)
	H.eq('R is unbound (was subtitle position)', mp.get_property_number('sub-pos'), sub_pos)
	H.eq('W is unbound (was pan-and-scan)', mp.get_property_number('panscan'), panscan)
	H.eq('BS is unbound (was speed reset)', mp.get_property_number('speed'), 2)

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
end)
