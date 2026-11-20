-- single-instance.lua - a file opened from Explorer while another plays: the
-- old one plays on, and two banners ask where the new one goes - here, in its
-- place, or to a new window that waits paused and minimized

local mp = require('mp')

local o = {
	banner_seconds = 15, -- how long the choice is offered; no click, and nothing changes
}
require('mp.options').read_options(o, 'single_instance')

-- the two banners, by the choice each one is
local BANNERS = { here = 'single-instance', window = 'single-instance-window' }
local SECTION = 'single-instance-click'
local STATE = 'user-data/single-instance'
-- a title in a banner's detail line, in bytes
local TITLE_BYTES = 50
-- files opened together come over about a second: the launchers take turns (mpv-single.cs TogetherMs)
local BURST_SECONDS = 1

local offer -- {old = {path, title}, files = {...}, launcher = <path>}
local expiry -- the timer that ends the offer with its banners
local boxes = {} -- the banners' rectangles {x, y, w, h} in OSD pixels by choice, once drawn
local over -- the choice whose banner is under the pointer
local leaving -- {files, launcher, timer}: "Play in a new window" taken, its burst's last files may still come
local last_open = 0 -- mp.get_time() of the last hand-off
local spawned

local function publish()
	mp.set_property_native(STATE, {
		offer = offer and { old = offer.old.path, files = offer.files } or nil,
		spawned = spawned,
	})
end

-- mpv turns a local path's / into \ (Windows), and Windows paths ignore case
local function same(a, b)
	return a ~= nil and b ~= nil and a:gsub('/', '\\'):lower() == b:gsub('/', '\\'):lower()
end

local function listed(list, path)
	for _, entry in ipairs(list) do
		if same(entry, path) then
			return true
		end
	end
	return false
end

local function shorten(s)
	if #s <= TITLE_BYTES then
		return s
	end
	local cut = TITLE_BYTES
	-- not inside a UTF-8 sequence: continuation bytes are 0x80-0xBF
	while cut > 1 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do
		cut = cut - 1
	end
	return s:sub(1, cut) .. '…'
end

-- the new files as a banner names them: the first one's name, and how many more
local function named(files)
	local name = shorten(files[1]:match('[^/\\]+$') or files[1])
	return #files > 1 and string.format('%s and %d more', name, #files - 1) or name
end

-- What plays, which a replace would end; nil when nothing would be lost by
-- replacing it (idle, or stopped at its end).
local function snapshot()
	local path = mp.get_property('path')
	if not path or mp.get_property_native('idle-active') or mp.get_property_native('eof-reached') then
		return nil
	end
	return { path = path, title = mp.get_property('media-title') or path }
end

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
		mp.enable_key_bindings(SECTION, 'allow-hide-cursor')
	end
end

local function on_mouse(_, pos)
	local now = offer ~= nil and under(pos) or nil
	if now then
		over = now
		raise()
		-- uosc reacts to the same move, in no set order with this script
		mp.add_timeout(0.05, raise)
	elseif over then
		over = nil
		mp.disable_key_bindings(SECTION)
	end
end

local function on_cards(_, notify)
	boxes = {}
	for _, card in ipairs(notify and notify.cards or {}) do
		for choice, id in pairs(BANNERS) do
			if card.id == id then
				boxes[choice] = card.box
			end
		end
	end
	on_mouse(nil, mp.get_property_native('mouse-pos'))
end

local function show_banners(current)
	local seconds = tostring(o.banner_seconds)
	local old = shorten(current.old.title)
	mp.commandv(
		'script-message-to',
		'notify',
		'show',
		BANNERS.here,
		'Play here',
		named(current.files) .. ', in place of ' .. old,
		seconds
	)
	mp.commandv(
		'script-message-to',
		'notify',
		'show',
		BANNERS.window,
		'Play in a new window',
		'It waits there paused; ' .. old .. ' plays on',
		seconds
	)
end

local function set_offer(new)
	if expiry then
		expiry:kill()
		expiry = nil
	end
	if offer and not new then
		mp.unobserve_property(on_mouse)
		mp.unobserve_property(on_cards)
		for _, id in pairs(BANNERS) do
			mp.commandv('script-message-to', 'notify', 'hide', id)
		end
		boxes = {}
	elseif new and not offer then
		mp.observe_property('user-data/notify', 'native', on_cards)
		mp.observe_property('mouse-pos', 'native', on_mouse)
	end
	offer = new
	if new then
		show_banners(new)
		expiry = mp.add_timeout(o.banner_seconds, function()
			set_offer(nil)
		end)
	else
		on_mouse(nil, nil)
	end
	publish()
end

local function play_here(files)
	mp.commandv('loadfile', files[1], 'replace')
	for i = 2, #files do
		mp.commandv('loadfile', files[i], 'append')
	end
end

local function start_window()
	local going = leaving
	if not going then
		return
	end
	if going.timer then
		going.timer:kill()
	end
	leaving = nil
	local args = { going.launcher, '--new-window', '--paused', '--' }
	for _, file in ipairs(going.files) do
		args[#args + 1] = file
	end
	spawned = args
	mp.command_native_async({
		name = 'subprocess',
		args = args,
		detach = true,
		playback_only = false,
	}, function() end)
	publish()
end

-- the new window once its burst is in: a file of it that came later would stay here
local function start_window_later()
	local going = leaving
	if not going then
		return
	end
	if going.timer then
		going.timer:kill()
	end
	local wait = last_open + BURST_SECONDS - mp.get_time()
	if wait > 0 then
		going.timer = mp.add_timeout(wait, start_window)
	else
		start_window()
	end
end

local function open(mode, launcher, ...)
	local files = { ... }
	if #files == 0 then
		return
	end
	last_open = mp.get_time()
	if mode == 'append' then
		local current = offer or leaving
		if current then
			-- opened together with the offered one: it goes where that one goes
			for _, file in ipairs(files) do
				if not listed(current.files, file) then
					current.files[#current.files + 1] = file
				end
			end
			if current == offer then
				show_banners(current)
				publish()
			else
				start_window_later()
			end
			return
		end
		-- not twice: autoload.lua queued the first file's folder before these came
		local queued = {}
		for i, entry in ipairs(mp.get_property_native('playlist') or {}) do
			queued[i] = entry.filename
		end
		for _, file in ipairs(files) do
			if not listed(queued, file) then
				mp.commandv('loadfile', file, 'append')
			end
		end
		return
	end
	local old = snapshot()
	if old and not same(old.path, files[1]) and launcher and launcher ~= '' then
		set_offer({ old = old, files = files, launcher = launcher })
		return
	end
	set_offer(nil)
	play_here(files)
end

-- here: the offered files in place of what plays; window: the launcher starts a
-- new mpv for them, paused and minimized (mpv-single.exe --paused)
local function choose(choice)
	local taken = offer
	if not taken or (choice ~= 'here' and choice ~= 'window') then
		return
	end
	set_offer(nil)
	if choice == 'here' then
		-- (a late file of its burst is appended here, as it should be)
		play_here(taken.files)
		return
	end
	leaving = { files = taken.files, launcher = taken.launcher }
	start_window_later()
end

-- The click takes the choice under the pointer on its release; the section stays a moment so a double click's
-- second press does nothing.
local function on_click()
	if not offer or not over then
		return
	end
	choose(over)
	mp.enable_key_bindings(SECTION, 'allow-hide-cursor')
	mp.add_timeout(0.5, function()
		if not over then
			mp.disable_key_bindings(SECTION)
		end
	end)
end

mp.set_key_bindings({
	{ 'mbtn_left', on_click },
	{ 'mbtn_left_dbl', function() end }, -- so input.conf's fullscreen double click does not fire on a banner
}, SECTION, 'force')

mp.register_script_message('open', open)
-- a banner's click without a pointer (tests): here or window
mp.register_script_message('choose', choose)

publish()
