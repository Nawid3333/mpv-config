-- speed-presets.lua - playback-speed preset keys that toggle back on repeat
--
-- Semantics (agreed with the user 2026-09-18): pressing a preset key sets its
-- speed; pressing the SAME key again reverts to the speed that was active just
-- before that key took effect. Memory is per key, for the current mpv session.
-- Example: q (3x) -> y (5x) -> y again -> back to 3x; then a (4x) remembers 3x,
-- and pressing a again reverts to 3x.
--
-- The memory is per KEY, not one global "previous speed": with one shared
-- value, q->y->y would revert to whatever was before q (say 1x), not to 3x as
-- the user described. Per-key state gives exactly "this key flips between its
-- own value and the speed you came from".
--
-- The preset value arrives via input.conf's script-binding arg
-- (`script-binding speed_presets/preset <value>`). Per AGENTS.md validation
-- item 2 (the script-binding/script-message bug), anything reached via
-- `script-binding <script>/<name>` MUST be registered with
-- mp.add_key_binding - a bare mp.register_script_message(name) is NOT called
-- by script-binding dispatch (mpv internally sends a "key-binding" message
-- that only the add_key_binding registry unpacks). The preset value then
-- arrives as the binding's `arg` event field, not as a message argument.
--
-- Deliberately NOT routed through here: the fine-adjust keys (s/d, [ ] { }) and
-- the uosc speed slider - those are adjustments, not presets, and tracking them
-- as "previous speed" would make the toggle target drift. They keep working
-- normally and simply become whatever the next preset press reverts to.
-- r IS routed through here (2026-09-19, at the user's request) as the 1x
-- preset: it resets to 1x, and pressing r again reverts to the previous speed
-- like any other preset key. The menu-only 0.5x/1.1x/1.5x entries in
-- input.conf remain plain `set speed` (menu extras, not keys).

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

--- A banner top LEFT (Scripts/notify.lua draws every message; the id "speed"
--- is shared with speed-button.lua, so one banner shows the latest speed).
--- Left side since 2026-09-28: the resolution banner and the shader/resume
--- messages keep the right corner; the speed keys' banner sits away from them.
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
		-- This preset is already active: press = revert to what preceded it.
		-- No memory yet (first press of this key since mpv started, e.g. the
		-- speed was restored from last session by remember-speed.lua): fall
		-- back to 1x so the first press always does something predictable.
		local prev = remembered[value] or 1
		if math.abs(current - prev) >= EPS then
			mp.set_property('speed', prev)
			notify('Speed ' .. fmt(prev), 'same key again: ' .. fmt(target))
			remembered[value] = target
		else
			-- nothing to go back to (r at 1x): the press still says the speed
			-- (review, 2026-10-09: it showed nothing at all)
			notify('Speed ' .. fmt(current), '')
		end
	else
		remembered[value] = current
		mp.set_property('speed', target)
		notify('Speed ' .. fmt(target), 'same key again: back to ' .. fmt(current))
	end
end

-- No default key: reachable only via input.conf's `script-binding speed_presets/preset <value>`.
-- complex = true is required to receive the event table carrying `arg` (the
-- script-binding argument); without it the handler is called with no
-- arguments at all (mp.defaults calls fn() plain). With complex, the handler
-- fires on down AND up - only act on the down/press event so one physical
-- press applies the preset exactly once.
mp.add_key_binding(nil, 'preset', function(event)
	if event.event == 'down' or event.event == 'press' then
		press(event.arg or '')
	end
end, { complex = true })
