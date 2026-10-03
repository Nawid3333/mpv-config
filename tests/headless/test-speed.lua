-- speed-presets.lua (preset keys toggle back on a repeat press, memory per key)
-- and speed-button.lua (toolbar left-click steps through the 0.5x list).
-- Semantics are the user-confirmed ones recorded in AGENTS.md.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function speed()
	return mp.get_property_number('speed')
end

H.run(function()
	mp.set_property_number('speed', 1)
	H.sleep(0.1)

	-- key -> preset value, as bound in input.conf
	local keys = { r = 1, g = 2, b = 2.5, q = 3, w = 3.5, a = 4, y = 5, e = 8, h = 16 }
	for key, value in pairs(keys) do
		if value ~= 1 then
			mp.set_property_number('speed', 1)
			H.key(key)
			H.expect('key ' .. key .. ' sets ' .. value .. 'x', speed, value, 0.001)
			H.key(key)
			H.expect('key ' .. key .. ' again reverts to 1x', speed, 1, 0.001)
		end
	end

	-- The documented sequence: q(3x) -> y(5x) -> y -> 3x; then a(4x), a -> 3x.
	mp.set_property_number('speed', 1)
	H.key('q')
	H.key('y')
	H.expect('q then y gives 5x', speed, 5, 0.001)
	H.key('y')
	H.expect('y again reverts to 3x (the speed before y)', speed, 3, 0.001)
	H.key('a')
	H.expect('a gives 4x', speed, 4, 0.001)
	H.key('a')
	H.expect('a again reverts to 3x', speed, 3, 0.001)

	-- Fine adjustment is not a preset: it just becomes what q reverts to.
	H.key('d')
	H.key('q')
	H.expect('q from 3.1x sets 3x', speed, 3, 0.001)
	H.key('q')
	H.expect('q again reverts to 3.1x', speed, 3.1, 0.001)

	-- r = the 1x preset: from 2x it resets, pressed again it goes back.
	mp.set_property_number('speed', 2)
	H.key('r')
	H.expect('r resets to 1x', speed, 1, 0.001)
	H.key('r')
	H.expect('r again goes back to 2x', speed, 2, 0.001)

	-- The uosc speed menu's items use the same binding with an argument.
	mp.set_property_number('speed', 1)
	mp.command('script-binding speed_presets/preset 2.5')
	H.sleep(0.15)
	H.expect('menu command form (script-binding ... preset 2.5) works', speed, 2.5, 0.001)

	-- Toolbar button left-click: next step of the 0.5x list, off-step speeds go
	-- to the next step up, 16x wraps to 0.5x.
	local steps = { { 1, 1.5 }, { 1.2, 1.5 }, { 2.5, 3 }, { 15.5, 16 }, { 16, 0.5 } }
	for _, s in ipairs(steps) do
		mp.set_property_number('speed', s[1])
		mp.commandv('script-message-to', 'speed_button', 'cycle-speed')
		H.sleep(0.15)
		H.eq(string.format('speed button click %gx -> %gx', s[1], s[2]), speed(), s[2], 0.001)
	end
end)
