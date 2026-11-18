-- speed-button.lua - the toolbar speed button: badge, click = next step, right-click = menu

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')

local SPEED_MIN = 0.5
local SPEED_STEP = 0.5
local SPEED_MAX = 16

local function build_speed_presets()
	local speeds = {}
	for speed = SPEED_MIN, SPEED_MAX + 0.0001, SPEED_STEP do
		speeds[#speeds + 1] = speed
	end
	return speeds
end

local speed_presets = build_speed_presets()

---@param speed number
---@return string
local function format_speed(speed)
	-- rounded first: after s/d, 1.1 is stored as 1.1000000000000001
	return (string.format('%.2f', speed):gsub('%.?0+$', '')) .. 'x'
end

-- Preset clicks go through speed-presets.lua, so the menu toggles back like the keys.
local function open_speed_menu()
	local current = mp.get_property_native('speed', 1)
	local items = {}
	for _, speed in ipairs(speed_presets) do
		items[#items + 1] = {
			title = format_speed(speed),
			value = 'script-binding speed_presets/preset ' .. tostring(speed),
			active = math.abs(speed - current) < 0.0001,
		}
	end

	local data = {
		type = 'speed-menu',
		title = 'Playback speed',
		items = items,
	}

	local json, err = utils.format_json(data)
	if json then
		mp.commandv('script-message-to', 'uosc', 'open-menu', json)
	else
		msg.error('Failed to format speed menu JSON: ' .. tostring(err))
	end
end

-- uosc's badge box holds 4 characters: a longer badge loses its "x", then is rounded.
local function badge_of(speed)
	local text = format_speed(speed)
	if #text > 4 then
		text = text:gsub('x$', '')
	end
	if #text > 4 then
		text = string.format('%d', math.floor(speed + 0.5))
	end
	return text
end

local function show_speed()
	local speed = mp.get_property_native('speed', 1)
	mp.commandv('script-message-to', 'notify', 'show', 'speed', 'Speed ' .. format_speed(speed), '', '', '', 'left')
end

-- Left-click: the next menu step, wrapping 16x -> 0.5x; a speed between steps goes to the next above.
local function cycle_speed()
	local current = mp.get_property_native('speed', 1)
	local next_speed = speed_presets[1]
	for _, speed in ipairs(speed_presets) do
		if speed > current + 0.0001 then
			next_speed = speed
			break
		end
	end
	mp.set_property_native('speed', next_speed)
	show_speed()
end

local function update_button()
	local speed = mp.get_property_native('speed', 1)
	local data = {
		icon = 'speed',
		badge = badge_of(speed),
		tooltip = string.format('Playback speed: %s - click: next, right-click: menu', format_speed(speed)),
		command = { 'script-message-to', mp.get_script_name(), 'cycle-speed' },
		menu_command = { 'script-message-to', mp.get_script_name(), 'open-speed-menu' },
	}

	local json, err = utils.format_json(data)
	if json then
		mp.commandv('script-message-to', 'uosc', 'set-button', 'speed', json)
	else
		msg.error('Failed to format speed button JSON: ' .. tostring(err))
	end
end

mp.observe_property('speed', 'native', update_button)
mp.register_script_message('open-speed-menu', open_speed_menu)
mp.register_script_message('cycle-speed', cycle_speed)
mp.register_script_message('show-speed', show_speed)

-- Initial update in case uosc loads after this script.
mp.add_timeout(0.5, update_button)
