-- skip-forward.lua - the forward skip keys (x, k, Right, the media Forward key): a skip
-- that would pass the end lands exactly on the end

local mp = require('mp')
local msg = require('mp.msg')

-- A skip that would land this close to the end (seconds) lands on the end.
local END_MARGIN = 1

local skips = 0

mp.register_script_message('skip', function(arg)
	local seconds = tonumber(arg)
	-- (seconds ~= seconds: NaN, which no comparison catches)
	if not seconds or seconds ~= seconds or seconds <= 0 then
		msg.warn('skip: a number of seconds above 0, not ' .. tostring(arg))
		return
	end
	-- time-pos is the target of a seek still under way (mpv's last seek position), so
	-- a second key pressed meanwhile counts on from where the first one goes
	local pos = mp.get_property_number('time-pos')
	local duration = mp.get_property_number('duration')
	local to_end = pos ~= nil and duration ~= nil and duration > 0 and pos + seconds >= duration - END_MARGIN
	local ok
	if to_end then
		ok = mp.commandv('seek', string.format('%.6f', duration), 'absolute+exact')
		if ok then
			mp.set_property_native('pause', false)
		end
	else
		-- a relative keyframe seek (hr-seek=default), no OSD (commandv's default)
		ok = mp.commandv('seek', tostring(seconds))
	end
	-- a failed command returns nil (AGENTS.md validation item 3): mpv logs why
	ok = ok == true
	if not ok then
		msg.verbose('skip ' .. seconds .. ' s: mpv refused the seek')
	end
	skips = skips + 1
	mp.set_property_native('user-data/skip-forward', {
		skips = skips,
		seconds = seconds,
		to_end = to_end,
		ok = ok,
	})
end)
