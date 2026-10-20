-- single-instance.lua - a file opened from Explorer plays in this window, and a
-- banner offers to keep what played
--
-- mpv-single.exe (what Explorer starts for mpv's file types) hands a local file
-- to the mpv window used last that plays a local file or nothing:
--   script-message-to single_instance open <replace|append> <launcher> <file>...
-- This script makes the playlist change itself, so it still knows what played:
-- when a replace stops a file before its end, a banner top right offers "Play
-- this in a new window" for banner_seconds (script-opt). A click on it puts the old playlist
-- back here - the same file at the same second, paused if it was - and starts
-- the launcher with --new-window for the new file(s), which go on in a second
-- window where they got to. Left alone, the banner goes and nothing else
-- happens. append (the rest of a burst of files opened together) only adds to
-- the playlist, and to what a click would move.
--
-- The click: the banner is notify.lua's card, and its box (user-data/notify)
-- the target. This script's mouse section is on only while the pointer is over
-- that box, and raised on every move there: uosc pushes its own click section
-- on top whenever the pointer crosses one of its zones. Anywhere else a click
-- stays input.conf's (pause).
--
-- State for tests: user-data/single-instance = {offer = {old = <path>, files =
-- {...}} while the banner offers the way back, spawned = the launcher's
-- arguments of the last click}.

local mp = require('mp')

local o = {
	banner_seconds = 8, -- how long the banner offers the way back
}
require('mp.options').read_options(o, 'single_instance')

local BANNER = 'single-instance'
local SECTION = 'single-instance-click'
local STATE = 'user-data/single-instance'
local KEEP_PAUSE = 'user-data/auto-start/keep-pause'
-- the old title in the banner's detail line, in bytes
local TITLE_BYTES = 60

local offer -- {old = snapshot(), files = {...}, launcher = <path>}
local expiry -- the timer that ends the offer with its banner
local box -- the banner's rectangle {x, y, w, h} in OSD pixels, once drawn
local over = false -- the pointer is over the banner
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

-- What plays, for the way back; nil when nothing would be lost by replacing
-- it (idle, or stopped at its end).
local function snapshot()
	local path = mp.get_property('path')
	if not path or mp.get_property_native('idle-active') or mp.get_property_native('eof-reached') then
		return nil
	end
	local entries = {}
	for i, entry in ipairs(mp.get_property_native('playlist') or {}) do
		entries[i] = entry.filename
	end
	return {
		path = path,
		title = mp.get_property('media-title') or path,
		pos = mp.get_property_number('time-pos'),
		pause = mp.get_property_native('pause'),
		playlist = entries,
		current = (mp.get_property_number('playlist-pos') or 0) + 1,
	}
end

local function inside(pos)
	return box ~= nil
		and pos ~= nil
		and pos.hover ~= false
		and pos.x >= box.x
		and pos.x <= box.x + box.w
		and pos.y >= box.y
		and pos.y <= box.y + box.h
end

local function raise()
	if over then
		mp.enable_key_bindings(SECTION, 'allow-hide-cursor')
	end
end

local function on_mouse(_, pos)
	local now = offer ~= nil and inside(pos)
	if now then
		over = true
		raise()
		-- uosc reacts to the same move, in no set order with this script
		mp.add_timeout(0.05, raise)
	elseif over then
		over = false
		mp.disable_key_bindings(SECTION)
	end
end

local function on_cards(_, notify)
	box = nil
	for _, card in ipairs(notify and notify.cards or {}) do
		if card.id == BANNER then
			box = card.box
		end
	end
	on_mouse(nil, mp.get_property_native('mouse-pos'))
end

local function set_offer(new)
	if expiry then
		expiry:kill()
		expiry = nil
	end
	if offer and not new then
		mp.unobserve_property(on_mouse)
		mp.unobserve_property(on_cards)
		mp.commandv('script-message-to', 'notify', 'hide', BANNER)
		box = nil
	elseif new and not offer then
		mp.observe_property('user-data/notify', 'native', on_cards)
		mp.observe_property('mouse-pos', 'native', on_mouse)
	end
	offer = new
	if new then
		mp.commandv(
			'script-message-to',
			'notify',
			'show',
			BANNER,
			'Play this in a new window',
			'Click, and ' .. shorten(new.old.title) .. ' plays on in this one',
			tostring(o.banner_seconds)
		)
		expiry = mp.add_timeout(o.banner_seconds, function()
			set_offer(nil)
		end)
	else
		on_mouse(nil, nil)
	end
	publish()
end

local function open(mode, launcher, ...)
	local files = { ... }
	if #files == 0 then
		return
	end
	if mode == 'append' then
		-- not twice: autoload.lua queued the first file's folder before these came
		local queued = {}
		for i, entry in ipairs(mp.get_property_native('playlist') or {}) do
			queued[i] = entry.filename
		end
		for _, file in ipairs(files) do
			if not listed(queued, file) then
				mp.commandv('loadfile', file, 'append')
			end
			if offer and not listed(offer.files, file) then
				offer.files[#offer.files + 1] = file
			end
		end
		publish()
		return
	end
	local old = snapshot()
	mp.commandv('loadfile', files[1], 'replace')
	for i = 2, #files do
		mp.commandv('loadfile', files[i], 'append')
	end
	if old and not same(old.path, files[1]) and launcher and launcher ~= '' then
		set_offer({ old = old, files = files, launcher = launcher })
	else
		set_offer(nil)
	end
end

local function accept()
	local taken = offer
	if not taken then
		return
	end
	set_offer(nil)
	-- the new file(s) go on in a new window, a single file where it got to
	local args = { taken.launcher, '--new-window' }
	local pos = mp.get_property_number('time-pos')
	-- (time-pos can be a little below 0 at a file's start)
	if #taken.files == 1 and pos and same(mp.get_property('path'), taken.files[1]) then
		args[#args + 1] = string.format('--start=%.3f', math.max(0, pos))
	end
	args[#args + 1] = '--'
	for _, file in ipairs(taken.files) do
		args[#args + 1] = file
	end
	spawned = args
	mp.command_native_async({
		name = 'subprocess',
		args = args,
		detach = true,
		playback_only = false,
	}, function() end)
	-- and the old playlist comes back here, the old file where it was
	local old = taken.old
	if old.pause then
		-- auto-start.lua clears an inherited pause, except for the file named here
		mp.set_property_native(KEEP_PAUSE, old.path)
		mp.set_property_native('pause', true)
	end
	mp.commandv(
		'loadfile',
		old.path,
		'replace',
		'-1',
		old.pos and string.format('start=%.3f', math.max(0, old.pos)) or ''
	)
	for i = 1, old.current - 1 do
		mp.commandv('loadfile', old.playlist[i], 'insert-at', tostring(i - 1))
	end
	for i = old.current + 1, #old.playlist do
		mp.commandv('loadfile', old.playlist[i], 'append')
	end
	publish()
end

-- The click takes the offer on its release, and the banner goes. The second
-- press of a double click, and the double click itself, would then reach
-- input.conf (pause, fullscreen): the section stays on a moment longer, doing
-- nothing.
local function on_click()
	if not offer then
		return
	end
	accept()
	mp.enable_key_bindings(SECTION, 'allow-hide-cursor')
	mp.add_timeout(0.5, function()
		if not over then
			mp.disable_key_bindings(SECTION)
		end
	end)
end

mp.set_key_bindings({
	{ 'mbtn_left', on_click },
	{ 'mbtn_left_dbl', function() end }, -- so input.conf's fullscreen double click does not fire on the banner
}, SECTION, 'force')

mp.register_script_message('open', open)
-- the banner's click without a pointer (tests)
mp.register_script_message('accept', accept)

publish()
