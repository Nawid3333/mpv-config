-- notify.lua in a window narrower than a banner (a small video): the card fits the window
-- instead of reaching past its left edge - a real window with a 320x180 clip drew the
-- single-instance banner from x=-57, its click target half off screen.
--
-- run-tests.ps1 runs this one on a real OSD surface (--vo=sixel) only 320 pixels wide.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function card(id)
	for _, c in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		if c.id == id then
			return c
		end
	end
end

H.run(function()
	local w = (mp.get_property_native('osd-dimensions') or {}).w or 0
	H.check('a narrow OSD surface', w > 0 and w < 400, 'osd width ' .. w)
	for _, side in ipairs({ '', 'left' }) do
		local id = 'narrow' .. side
		mp.commandv(
			'script-message-to',
			'notify',
			'show',
			id,
			'A title that is long enough to matter',
			'and a detail line that is a good deal longer than the narrow window it is shown in',
			'0',
			'',
			side
		)
		H.expect('the banner is drawn' .. (side ~= '' and ' (left)' or ''), function()
			local c = card(id)
			return c ~= nil and c.box ~= nil
		end, true, nil, 5)
		local box = (card(id) or {}).box or { x = -1, w = 0 }
		H.check(
			'... inside the window' .. (side ~= '' and ' (left)' or ''),
			box.x >= 0 and box.x + box.w <= w,
			string.format('x %d, w %d, window %d', box.x, box.w, w)
		)
		mp.commandv('script-message-to', 'notify', 'hide', id)
	end
end)
