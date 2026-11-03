-- skip-forward.lua - the forward skip keys (x, k, Right, the media Forward key): a skip
-- that would pass the end lands exactly on the end
--
-- A file's end is what FastStream's autoplay waits for (keep-open stops there, paused,
-- eof-reached), so a skip to the end has to arrive there. mpv's own `seek <n>` past the
-- end of an HLS stream whose end is not buffered yet asks the demuxer, and FFmpeg's HLS
-- demuxer refuses a time after the playlist's duration ("[lavf] Seek failed" in mpv's
-- log): mpv then went on from the end of what was buffered - up to minutes before the
-- end - and played on, or stayed there while paused. No end came, and no autoplay. An
-- exact seek to the duration itself is a time inside the file: it decodes from the last
-- keyframe to the last frame (measured on HLS streams, muxed and with separate audio
-- playlists: the end within 0.2 s; doc/history). Playback then goes on: paused, mpv
-- showed the last frame of some files and never marked their end, which comes only when
-- playback asks for the frame after it; keep-open pauses at the end again, as at any end.
-- A skip that would land in the last second goes to the end too: a keyframe seek
-- there could stop seconds short of it (paused, 0.3 s before the end asked, 2.4 s before
-- it landed, no end). Every other skip stays mpv's instant keyframe seek, as before.
--
-- input.conf: `x script-message-to skip_forward skip 60` (and 10, 5, 60).
-- State for tests: user-data/skip-forward = {skips, seconds, to_end (went to the end),
-- ok (mpv took the seek)}.

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
		-- a relative seek with no flags: a keyframe seek (hr-seek=default), no OSD
		-- (commandv's default)
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
