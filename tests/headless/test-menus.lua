-- The menus our scripts hand to uosc really open: gpu-toggles' upscale menu
-- and speed-button's speed menu are JSON built in Lua, and a malformed one
-- simply never shows. uosc publishes the open menu's type in
-- user-data/uosc/menu/type, so no rendering is needed to see it opened.
-- Also: right-click opens uosc's main menu (input.conf mbtn_right).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function menu_type()
	return mp.get_property_native('user-data/uosc/menu/type')
end

local function expect_menu(name, open, want)
	open()
	H.wait_until(function()
		return menu_type() == want
	end, 3)
	H.eq(name, menu_type(), want)
	mp.commandv('script-message-to', 'uosc', 'close-menu')
	H.wait_until(function()
		return menu_type() == nil
	end, 3)
end

H.run(function()
	expect_menu('toolbar right-click on upscale opens the upscale menu', function()
		mp.commandv('script-message-to', 'gpu_toggles', 'open-upscale-menu')
	end, 'upscale-menu')
	expect_menu('toolbar right-click on speed opens the speed menu', function()
		mp.commandv('script-message-to', 'speed_button', 'open-speed-menu')
	end, 'speed-menu')
	expect_menu('right-click opens the uosc menu', function()
		mp.commandv('keypress', 'MBTN_RIGHT')
	end, 'menu')
end)
