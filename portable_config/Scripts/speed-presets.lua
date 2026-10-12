-- speed-presets.lua - playback-speed preset keys that toggle back on repeat
--
-- A preset key sets its speed; the SAME key again goes back to the speed that
-- was active before that key took effect. The memory is per key and per session:
-- q (3x) -> y (5x) -> y -> 3x; one shared "previous speed" would send that last
-- y back to whatever came before q.
--
-- The value arrives as the binding's `arg` (input.conf: `script-binding
-- speed_presets/preset <value>`). script-binding only reaches handlers added with
-- mp.add_key_binding, never mp.register_script_message.
--
-- r is the 1x preset. s/d, [ ] { } and the uosc slider are adjustments, not
-- presets: they do not move a key's memory, they just become what the next
-- preset press goes back to.

local mp = require('mp')
local msg = require('mp.msg')

local EPS = 0.0001

--- remembered[preset] = the speed that was active before this preset last took effect
local remembered = {}

--- Format a speed the way the banner and badge show it ("3x", "2.5x").
---@param speed number
---@return string
local function fmt(speed)
	-- rounded first: after s/d, 1.1 is stored as 1.1000000000000001
	return (string.format('%.2f', speed):gsub('%.?0+$', '')) .. 'x'
end

--- A banner top LEFT, away from the video and shader banners on the right
--- (notify.lua; the id "speed" is shared with speed-button.lua, so one banner
--- shows the latest speed).
---@param title string
---@param detail string
local function notify(title, detail)
	mp.commandv('script-message-to', 'notify', 'show', 'speed', title, detail, '', '', 'left')
end

--- Apply one preset press. `value` is the preset's speed as a string
--- (passed through input.conf's script-binding arg).
---@param value string
local function press(value)
	local target = tonumber(value)
	if not target or target <= 0 then
		msg.warn('bad preset speed: ' .. tostring(value))
		return
	end
	local current = mp.get_property_native('speed', 1)
	if math.abs(current - target) < EPS then
		-- Already active: go back to what preceded it - 1x when this key has
		-- no memory yet (e.g. the speed was restored by remember-speed.lua).
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

-- complex = true is needed to receive `arg`; it also delivers down AND up, so
-- only down/press applies the preset (once per physical press).
mp.add_key_binding(nil, 'preset', function(event)
	if event.event == 'down' or event.event == 'press' then
		press(event.arg or '')
	end
end, { complex = true })
