-- percent-seek.lua - the number keys: key N jumps to N x 10 %, from the buffer when it
-- holds that spot

local mp = require('mp')
local msg = require('mp.msg')

local jumps = 0

-- Whether mpv's cache can seek to `t`: inside a seekable range, or before the first / after the last.
local function buffered(t)
	local s = mp.get_property_native('demuxer-cache-state')
	if type(s) ~= 'table' or type(s['seekable-ranges']) ~= 'table' then
		return false
	end
	local lowest, highest = nil, nil
	for _, r in ipairs(s['seekable-ranges']) do
		local a, b = r.start, r['end']
		if type(a) == 'number' and type(b) == 'number' then
			if t >= a and t <= b then
				return true
			end
			if not lowest or a < lowest.start then
				lowest = r
			end
			if not highest or b > highest['end'] then
				highest = r
			end
		end
	end
	return (s['bof-cached'] == true and lowest ~= nil and t < lowest.start)
		or (s['eof-cached'] == true and highest ~= nil and t > highest['end'])
end

mp.register_script_message('jump', function(arg)
	local percent = tonumber(arg)
	-- (percent ~= percent: NaN, which no comparison catches)
	if not percent or percent ~= percent or percent < 0 or percent > 100 then
		msg.warn('jump: a percent from 0 to 100, not ' .. tostring(arg))
		return
	end
	local duration = mp.get_property_number('duration')
	local time = (duration and duration > 0) and percent / 100 * duration or nil
	local from_buffer = time ~= nil and buffered(time)
	local ok
	if from_buffer then
		ok = mp.commandv('seek', string.format('%.6f', time), 'absolute+keyframes')
	else
		ok = mp.commandv('seek', tostring(percent), 'absolute-percent+keyframes')
	end
	-- a failed command returns nil (AGENTS.md validation item 3): mpv logs why
	ok = ok == true
	if not ok then
		msg.verbose('jump to ' .. percent .. ' %: mpv refused the seek')
	end
	jumps = jumps + 1
	mp.set_property_native('user-data/percent-seek', {
		jumps = jumps,
		percent = percent,
		time = time,
		buffered = from_buffer,
		ok = ok,
	})
end)
