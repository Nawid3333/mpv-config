-- percent-seek.lua - the number keys: key N jumps to N x 10 %, from the buffer when it
-- holds that spot
--
-- mpv's own `seek <p> absolute-percent+keyframes` never looks in the buffer on a source
-- whose timestamps may reset - HLS and MPEG-TS, i.e. most FastStream streams: there it
-- asks the demuxer for a fraction of the file (a byte position, or lavf's own duration),
-- and mpv's demuxer cache answers only time seeks. A jump into video that was already
-- buffered so read it all again, and kept the old copy beside the new one (measured on
-- a throttled HLS stream: 0-152 s buffered, key 2 downloaded 68-122 s a second time; a
-- timeline click, an absolute seek, came from the buffer). A target inside a range the
-- buffer holds is sent as the time mpv itself makes of a percent seek on other sources
-- (percent x duration), which the cache serves. Any other target stays mpv's percent
-- seek: nothing to keep there, and on a TS file whose timestamps jump the byte seek is
-- the one that lands. Both are instant keyframe seeks, and no OSD (commandv's default).
--
-- input.conf: `N script-message-to percent_seek jump <N x 10>`.
-- State for tests: user-data/percent-seek = {jumps, percent, time (nil: no duration),
-- buffered (went to the buffer), ok (mpv took the seek)}.

local mp = require('mp')
local msg = require('mp.msg')

local jumps = 0

-- Whether mpv's cache can seek to `t` (playback time): it lies in a seekable range, or
-- before the range that starts the stream / after the one that ends it (mpv seeks into
-- those from anywhere before their first or after their last keyframe). Without a
-- seekable cache mpv reports no ranges.
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
