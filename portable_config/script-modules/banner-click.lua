-- banner-click.lua - a click on notify.lua's banners (single-instance.lua, faststream-offer.lua). The banners' boxes
-- (user-data/notify) are the targets; a forced key section takes the click only while the pointer is over one, so a
-- click anywhere else stays input.conf's (pause). Loaded with dofile().

local mp = require('mp')

local M = {}

-- mp.get_time() until which no banner takes a click, for every script that uses this: one script's banners going
-- can move another's under the pointer, and a double click's second press would take that one's choice
local GUARD = 'user-data/banner-click/until'
local GUARD_SECONDS = 0.5

---@param section string the key section's name, one per script
---@param ids table<string, string> the banners' notify ids by choice
---@param on_click fun(choice: string)
---@return {watch: fun(), stop: fun()}
function M.new(section, ids, on_click)
	local watching = false
	local boxes = {} -- the banners' rectangles {x, y, w, h} in OSD pixels by choice, once drawn
	local over -- the choice whose banner is under the pointer

	local function under(pos)
		if pos == nil or pos.hover == false then
			return nil
		end
		for choice, box in pairs(boxes) do
			if pos.x >= box.x and pos.x <= box.x + box.w and pos.y >= box.y and pos.y <= box.y + box.h then
				return choice
			end
		end
		return nil
	end

	local function raise()
		if over then
			mp.enable_key_bindings(section, 'allow-hide-cursor')
		end
	end

	local function on_mouse(_, pos)
		local now = watching and under(pos) or nil
		if now then
			over = now
			raise()
			-- uosc pushes its own click section whenever the pointer crosses one of its zones, in no set order with
			-- this script
			mp.add_timeout(0.05, raise)
		elseif over then
			over = nil
			mp.disable_key_bindings(section)
		end
	end

	local function on_cards(_, notify)
		boxes = {}
		for _, card in ipairs(notify and notify.cards or {}) do
			for choice, id in pairs(ids) do
				if card.id == id then
					boxes[choice] = card.box
				end
			end
		end
		on_mouse(nil, mp.get_property_native('mouse-pos'))
	end

	-- The click takes the choice under the pointer on its release; the section stays a moment so a double click's
	-- second press does nothing.
	local function click()
		if not watching or not over or (mp.get_property_number(GUARD) or 0) > mp.get_time() then
			return
		end
		mp.set_property_native(GUARD, mp.get_time() + GUARD_SECONDS)
		on_click(over)
		mp.enable_key_bindings(section, 'allow-hide-cursor')
		mp.add_timeout(GUARD_SECONDS, function()
			if not over then
				mp.disable_key_bindings(section)
			end
		end)
	end

	mp.set_key_bindings({
		{ 'mbtn_left', click },
		{ 'mbtn_left_dbl', function() end }, -- so input.conf's fullscreen double click does not fire on a banner
	}, section, 'force')

	local handle = {}

	--- The banners are up: a click on one is theirs.
	function handle.watch()
		if watching then
			return
		end
		watching = true
		mp.observe_property('user-data/notify', 'native', on_cards)
		mp.observe_property('mouse-pos', 'native', on_mouse)
	end

	--- The banners are gone: every click is input.conf's again.
	function handle.stop()
		if not watching then
			return
		end
		watching = false
		mp.unobserve_property(on_cards)
		mp.unobserve_property(on_mouse)
		boxes = {}
		on_mouse(nil, nil)
	end

	--- The banners now ask something else: a click on its way was meant for what they showed before.
	function handle.hold()
		mp.set_property_native(GUARD, mp.get_time() + GUARD_SECONDS)
	end

	return handle
end

return M
