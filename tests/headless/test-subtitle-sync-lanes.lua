-- subtitle-sync.lua: overlapping subtitle lines go on two lanes, and a click on a block
-- jumps to the start of THAT line. It jumped to the first line running at that time,
-- often the other one: a long sign (1-15 s) and a line spoken over it (5-7 s).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function state()
	return mp.get_property_native('user-data/subtitle-sync') or {}
end

local function block(start)
	for _, b in ipairs(state().blocks or {}) do
		if math.abs(b.s - start) < 0.01 then
			return b
		end
	end
end

H.run(function()
	local tmp = os.getenv('TEMP') or os.getenv('TMP') or '.'
	local srt = tmp .. '\\subsync-lanes.srt'
	local f = assert(io.open(srt, 'w'))
	f:write('1\n00:00:01,000 --> 00:00:15,000\na long sign\n\n')
	f:write('2\n00:00:05,000 --> 00:00:07,000\na line spoken over it\n\n')
	f:close()
	mp.set_property_native('pause', true)
	mp.commandv('sub-add', srt, 'select')
	mp.commandv('seek', '6', 'absolute+exact')
	H.sleep(0.3)
	H.key('t')
	H.expect('t opens the panel', function()
		return state().open
	end, true)
	H.expect('both lines are read', function()
		return state().cues
	end, 2, nil, 5)
	H.expect('both are drawn', function()
		return #(state().blocks or {})
	end, 2, nil, 5)
	local sign, spoken = block(1), block(5)
	H.check('... on two lanes', sign and spoken and spoken.y0 >= sign.y1, '')
	-- the spoken line's block, at 6 s, where the sign runs too
	H.click(math.floor((spoken.x0 + spoken.x1) / 2), math.floor((spoken.y0 + spoken.y1) / 2))
	H.expect('a click on the lower lane jumps to that line (5 s)', function()
		return mp.get_property_number('time-pos')
	end, 5, 0.06)
	-- the sign's block at a time the spoken line runs too (the view moved with the jump)
	H.sleep(0.3)
	sign, spoken = block(1), block(5)
	H.click(math.floor((spoken.x0 + spoken.x1) / 2), math.floor((sign.y0 + sign.y1) / 2))
	H.expect('a click on the upper lane at that time jumps to the sign (1 s)', function()
		return mp.get_property_number('time-pos')
	end, 1, 0.06)
	H.key('t')
	os.remove(srt)
end)
