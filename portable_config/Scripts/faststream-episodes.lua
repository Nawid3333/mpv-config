-- faststream-episodes.lua - previous / next episode and the autoplay switch as
-- buttons in uosc's control bar, while FastStream plays a series in this window.
--
-- uosc's own prev / next are playlist buttons, and a FastStream stream is a
-- playlist of one, so they do nothing here; mpv itself offers no autoplay switch.
--
-- The FastStream helper follows the mpv it started over JSON IPC. It sets these
-- properties:
--   user-data/faststream/connected  true while it follows this window; missing
--                                   counts as false.
--   user-data/faststream/heartbeat  the time, written when it connects and every
--                                   30 s after. A helper killed hard (Task
--                                   Manager, a Firefox crash) clears nothing: once
--                                   this value has stood still for 90 s (three
--                                   beats missed) it counts as gone and the
--                                   buttons go. A helper that never writes one is
--                                   followed by `connected` alone.
--   user-data/faststream/autoplay   its "Autoplay next episode in mpv" setting
-- and hears every client message:
--   script-message faststream-next / faststream-previous (also n / Shift+N / Shift+P and the
--   media keys, input.conf); without a helper the playlist's next / previous file instead
--   script-message faststream-autoplay (also Ctrl+a): it flips the setting, stores
--       it, sets user-data/faststream/autoplay to the new value and says so in a
--       notify.lua banner. Switched off during its 5 s countdown at an episode's
--       end, it cancels the countdown.
--
-- The three buttons are managed uosc buttons (uosc.conf controls=, their look
-- pushed with script-message-to uosc set-button, as gpu-toggles.lua,
-- source-info.lua and settings.lua do). They show only while FastStream follows
-- this window AND the file is a stream it sent; anywhere else they take no space.
-- Each push carries `hide`, and uosc.conf gives the buttons and the gap after them
-- the disposition <user-data/faststream-episodes/shown>, which this script sets
-- true only once uosc has all three: that also keeps them away until the first
-- push reaches uosc, which draws an uninitialised managed button as a question
-- mark.
--
-- The keys (n, N, Ctrl+a) and the Playlist menu's entries send the same messages
-- in any window. With a helper following, the helper acts on them and speaks;
-- without one (a file opened in mpv itself, FastStream not in MPV mode, a helper
-- that stopped beating) this script answers with a banner.
--
-- For the tests: user-data/faststream-episodes/buttons holds what was last pushed
-- for each button.

local mp = require('mp')
local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')
-- the FastStream tags in the URL fragment (AGENTS.md, "FastStream contract")
local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))

local opts = {
	-- seconds without a new heartbeat before the helper counts as gone (the tests
	-- shorten it); the helper beats every 30 s
	heartbeat_stale = 90,
}
options.read_options(opts, 'faststream_episodes')

local state = {
	connected = false, -- user-data/faststream/connected, and the helper alive
	autoplay = false, -- user-data/faststream/autoplay
	path = nil, -- the current file's path, nil when nothing is loaded
}

-- the last heartbeat heard (mp.get_time()), nil until a helper sent one
local beat_at = nil

local function helper_alive()
	return beat_at == nil or mp.get_time() - beat_at <= opts.heartbeat_stale
end

-- The helper sets booleans over JSON IPC. A `set` from a command string would
-- store the text instead, so "yes" and "true" count too.
local function truthy(value)
	return value == true or value == 'yes' or value == 'true'
end

--- Whether `path` is a stream FastStream sent: a whole fs-content= or fs-id= item
--- with a value in its URL fragment (everything after the first '#', items
--- separated by '&'), as gpu-toggles.lua and stream-resume.lua read them. Not the
--- text anywhere in the address: a site's own query or fragment item
--- ("?x=fs-content=anime", "#xfs-id=...") is no tag.
---@param path string|nil
---@return boolean
local function is_faststream(path)
	for _, marker in ipairs({ 'fs-content=', 'fs-id=' }) do
		local value = fragment.value(path, marker)
		if value and value ~= '' then
			return true
		end
	end
	return false
end

-- ---- the buttons --------------------------------------------------------------------

local pushed = {} -- name -> the JSON uosc last got
local published = {} -- name -> the data of the last push, for the tests
local delivered = true -- uosc has all three as the last update made them

--- Sends a button's look to uosc unless uosc has it already; true when it has.
---@return boolean
local function push(name, data)
	local json, err = utils.format_json(data)
	if not json then
		msg.error('button ' .. name .. ': ' .. tostring(err))
		return false
	end
	published[name] = data
	if pushed[name] == json then
		return true -- unchanged: uosc's set-button repaints the whole UI every time
	end
	-- remembered only once sent: before uosc has started there is nobody to send to,
	-- and the next update has to try again
	if mp.commandv('script-message-to', 'uosc', 'set-button', name, json) then
		pushed[name] = json
		return true
	end
	return false
end

local function update()
	local shown = state.connected and is_faststream(state.path)
	local prev_sent = push('episode_prev', {
		icon = 'skip_previous',
		tooltip = 'Previous episode',
		command = { 'script-message', 'faststream-previous' },
		hide = not shown,
	})
	local next_sent = push('episode_next', {
		icon = 'skip_next',
		tooltip = 'Next episode',
		command = { 'script-message', 'faststream-next' },
		hide = not shown,
	})
	local autoplay_sent = push('autoplay', {
		icon = 'playlist_play',
		active = state.autoplay,
		tooltip = 'Autoplay next episode: ' .. (state.autoplay and 'on' or 'off'),
		command = { 'script-message', 'faststream-autoplay' },
		hide = not shown,
	})
	-- The flag uosc.conf's disposition reads (uosc lays its bar out again when it
	-- changes): never true for a button uosc has not got, which it would draw as a
	-- question mark. The once-a-second look below sends it again.
	delivered = prev_sent and next_sent and autoplay_sent
	mp.set_property_native('user-data/faststream-episodes/shown', shown and delivered)
	mp.set_property_native('user-data/faststream-episodes/buttons', published)
end

-- ---- what they follow ---------------------------------------------------------------

-- Reads both properties again; nothing to do when neither changed and uosc has
-- every button.
local function read_helper()
	local connected = truthy(mp.get_property_native('user-data/faststream/connected')) and helper_alive()
	local autoplay = truthy(mp.get_property_native('user-data/faststream/autoplay'))
	if connected ~= state.connected or autoplay ~= state.autoplay or not delivered then
		state.connected, state.autoplay = connected, autoplay
		update()
	end
end

-- mpv tells no observer when a user-data key is deleted: neither the key's
-- observers nor its map's hear it, and a deleted `connected` counts as false. So
-- while the last value the observer heard is true, a look once a second catches a
-- helper that deletes the key instead of setting false - and one that sets true
-- again after that, which the observer, still holding true, does not report
-- either. The same look sends a button uosc did not get yet, and notices a
-- heartbeat that stopped (a killed helper changes nothing mpv could hear).
local recheck = mp.add_periodic_timer(1, read_helper)
recheck:kill()

mp.observe_property('user-data/faststream/connected', 'native', function(_, value)
	if truthy(value) then
		recheck:resume()
	else
		recheck:kill()
	end
	read_helper()
end)

mp.observe_property('user-data/faststream/autoplay', 'native', read_helper)

-- a new value with every beat; the first one of a helper started after a killed
-- one is a change too (the time keeps rising)
mp.observe_property('user-data/faststream/heartbeat', 'native', function(_, value)
	if value ~= nil then
		beat_at = mp.get_time()
	end
	read_helper()
end)

-- Between two files `path` is gone for a moment. Keeping the last one then spares
-- the bar a hide and show while the next episode loads; idle-active clears it once
-- nothing is loaded any more.
mp.observe_property('path', 'string', function(_, path)
	if path then
		state.path = path
		update()
	end
end)

mp.observe_property('idle-active', 'bool', function(_, idle)
	if idle then
		state.path = nil
		update()
	end
end)

-- as the other managed buttons: uosc may start after this script
mp.add_timeout(0.5, update)

-- ---- the keys without a helper ------------------------------------------------------

local KEY_TITLES = {
	['faststream-next'] = 'Next episode',
	['faststream-previous'] = 'Previous episode',
	['faststream-autoplay'] = 'Autoplay',
}

-- next / previous with no helper, for a video FastStream did not send: the playlist's
-- neighbour - for a local file the next file of its folder (autoload.lua queues the
-- folder), an episode as well. A FastStream video's episodes are the page's, which only
-- its helper can open: the banner says so, as before.
local PLAYLIST_STEP = {
	['faststream-next'] = 'playlist-next',
	['faststream-previous'] = 'playlist-prev',
}

for name, title in pairs(KEY_TITLES) do
	mp.register_script_message(name, function()
		-- read now, not state.connected: that one follows a stopped heartbeat only
		-- at the next once-a-second look
		if truthy(mp.get_property_native('user-data/faststream/connected')) and helper_alive() then
			return
		end
		local path = mp.get_property('path')
		local step = not is_faststream(path) and PLAYLIST_STEP[name]
		-- a failing command returns nil (AGENTS.md validation item 3): no file there
		if step and mp.commandv(step) then
			return
		end
		local detail = 'only for videos FastStream sends to mpv'
		if step and path and not path:find('^%a[%w+.-]*://') then
			detail = step == 'playlist-next' and 'this is the last file of its folder'
				or 'this is the first file of its folder'
		elseif step then
			detail = step == 'playlist-next' and 'nothing after it in the playlist'
				or 'nothing before it in the playlist'
		end
		mp.commandv('script-message-to', 'notify', 'show', 'faststream', title, detail, '4')
	end)
end
