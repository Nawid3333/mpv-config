-- speed-presets.lua - playback-speed preset keys that toggle back on repeat
local mp = require('mp')
local msg = require('mp.msg')

local EPS = 0.0001

local remembered = {}

---@param speed number
---@return string
local function fmt(speed)
	-- rounded first: after s/d, 1.1 is stored as 1.1000000000000001
	return (string.format('%.2f', speed):gsub('%.?0+$', '')) .. 'x'
end

---@param title string
---@param detail string
local function notify(title, detail)
	mp.commandv('script-message-to', 'notify', 'show', 'speed', title, detail, '', '', 'left')
end

---@param value string
local function press(value)
	local target = tonumber(value)
	if not target or target <= 0 then
		msg.warn('bad preset speed: ' .. tostring(value))
		return
	end
	local current = mp.get_property_native('speed', 1)
	if math.abs(current - target) < EPS then
		-- Already active: back to what preceded it (1x when this key has no memory yet).
		local prev = remembered[value] or 1
		if math.abs(current - prev) >= EPS then
			mp.set_property('speed', prev)
			notify('Speed ' .. fmt(prev), 'same key again: ' .. fmt(target))
			remembered[value] = target
		else
			-- nothing to go back to (r at 1x): the press still shows the speed
			notify('Speed ' .. fmt(current), '')
		end
	else
		remembered[value] = current
		mp.set_property('speed', target)
		notify('Speed ' .. fmt(target), 'same key again: back to ' .. fmt(current))
	end
end

-- complex = true delivers `arg`, and both down and up: only down/press applies the preset.
mp.add_key_binding(nil, 'preset', function(event)
	if event.event == 'down' or event.event == 'press' then
		press(event.arg or '')
	end
end, { complex = true })
