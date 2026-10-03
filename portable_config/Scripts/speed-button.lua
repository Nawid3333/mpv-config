-- Speed button for uosc toolbar
-- Shows current playback speed as a badge; left-click steps to the next speed, right-click opens the menu.

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

-- Full menu list: 0.5x, 1x, 1.5x, 2x, 2.5x, ..., 16x
local speed_presets = build_speed_presets()

--- Format speed as a short badge string (e.g. "1x", "1.5x", "0.75x").
---@param speed number
---@return string
local function format_speed(speed)
	-- Rounded first: s/d add 0.1 in floating point, and 1.1 is stored as
	-- 1.1000000000000001 - the old exact test printed "1.10x", too wide for
	-- the 4-character badge.
	return (string.format('%.2f', speed):gsub('%.?0+$', '')) .. 'x'
end

--- Open a speed-selection menu with the full stepped list.
--- Preset clicks are routed through Scripts/speed-presets.lua so the menu
--- behaves exactly like the preset KEYS in input.conf: picking a preset that
--- is already active reverts to the previous speed instead of doing nothing.
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

--- A banner top LEFT with the current speed (Scripts/notify.lua draws every
--- message; the id "speed" is shared with speed-presets.lua). Left side since
--- 2026-09-28, like the speed keys' banner: the right corner keeps the video
--- info and the shader/resume messages. Also reached from input.conf (s/d,
--- [ ] { }, the menu's extra speeds) as `show-speed`, after a `no-osd` speed
--- change, so every speed change looks the same.
local function show_speed()
	local speed = mp.get_property_native('speed', 1)
	mp.commandv('script-message-to', 'notify', 'show', 'speed', 'Speed ' .. format_speed(speed), '', '', '', 'left')
end

--- Left-click: step to the next entry of the menu list, wrapping 16x -> 0.5x.
--- A speed between steps (e.g. 1.3x from s/d) goes to the next step above it.
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

--- Update the uosc button:speed managed button.
local function update_button()
	local speed = mp.get_property_native('speed', 1)
	local data = {
		icon = 'speed',
		badge = format_speed(speed),
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
