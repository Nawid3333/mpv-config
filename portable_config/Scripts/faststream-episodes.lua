-- faststream-episodes.lua - previous / next episode and the autoplay switch as
-- buttons in uosc's control bar, while FastStream plays a series in this window.

local mp = require('mp')
local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')
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

local pushed = {} -- name -> the JSON uosc last got
local published = {} -- name -> the data of the last push, for the tests
local delivered = true -- uosc has all three as the last update made them

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
	-- The flag uosc.conf's disposition reads: never true for a button uosc has not got (drawn as a question mark).
	delivered = prev_sent and next_sent and autoplay_sent
	mp.set_property_native('user-data/faststream-episodes/shown', shown and delivered)
	mp.set_property_native('user-data/faststream-episodes/buttons', published)
end

local function read_helper()
	local connected = truthy(mp.get_property_native('user-data/faststream/connected')) and helper_alive()
	local autoplay = truthy(mp.get_property_native('user-data/faststream/autoplay'))
	if connected ~= state.connected or autoplay ~= state.autoplay or not delivered then
		state.connected, state.autoplay = connected, autoplay
		update()
	end
end

-- mpv tells no observer when a user-data key is deleted, nor of a true set again after that: a look once a second
-- catches both, sends a button uosc did not get yet, and notices a heartbeat that stopped.
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

-- Between two files `path` is gone a moment: the last one is kept, sparing the bar a hide and show.
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

local KEY_TITLES = {
	['faststream-next'] = 'Next episode',
	['faststream-previous'] = 'Previous episode',
	['faststream-autoplay'] = 'Autoplay',
}

-- next / previous without a helper, for a video FastStream did not send: the playlist's neighbour
-- (autoload.lua queues a local file's folder); a FastStream video's episodes only its helper can open.
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
