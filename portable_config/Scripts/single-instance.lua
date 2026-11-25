-- single-instance.lua - a file opened from Explorer while another plays: the
-- old one plays on, and banners ask where the new one goes - here, in its
-- place, behind it in the queue (queue/main.lua), or to a new window that waits
-- paused and minimized

local mp = require('mp')
local clicks = dofile(mp.command_native({ 'expand-path', '~~/script-modules/banner-click.lua' }))

local o = {
	banner_seconds = 15, -- how long the choice is offered; no click: into the queue if there is one, else nothing
}
require('mp.options').read_options(o, 'single_instance')

-- the banners, by the choice each one is
local BANNERS = { here = 'single-instance', queue = 'single-instance-queue', window = 'single-instance-window' }
local STATE = 'user-data/single-instance'
-- a title in a banner's detail line, in bytes
local TITLE_BYTES = 50
-- files opened together come over about a second: the launchers take turns (mpv-single.cs TogetherMs)
local BURST_SECONDS = 1

local offer -- {old = {path, title}, files = {...}, launcher = <path>}
local expiry -- the timer that ends the offer with its banners
local banners -- (below) their clicks (banner-click.lua)
local leaving -- {files, launcher, timer}: "Play in a new window" taken, its burst's last files may still come
local queuing = false -- "Add to queue" taken: its burst's last files go to the queue too
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

--- How many wait in the queue; nil without queue/main.lua (no queue banner then).
---@return integer|nil
local function queued()
	local state = mp.get_property_native('user-data/queue')
	return type(state) == 'table' and tonumber(state.count) or nil
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
	local waiting = queued()
	if waiting then
		mp.commandv(
			'script-message-to',
			'notify',
			'show',
			BANNERS.queue,
			'Add to queue',
			waiting == 0 and ('Plays after ' .. old) or string.format('Plays after the %d in the queue', waiting),
			seconds
		)
	end
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

local on_ended -- (below) what plays came to its end while the banners ask
local choose -- (below) a banner's choice

local function set_offer(new)
	if expiry then
		expiry:kill()
		expiry = nil
	end
	if offer and not new then
		banners.stop()
		mp.unobserve_property(on_ended)
		for _, id in pairs(BANNERS) do
			mp.commandv('script-message-to', 'notify', 'hide', id)
		end
	elseif new and not offer then
		banners.watch()
		mp.observe_property('eof-reached', 'bool', on_ended)
		mp.observe_property('idle-active', 'bool', on_ended)
	elseif new then
		-- a click on its way was meant for the offer before
		banners.hold()
	end
	offer = new
	if new then
		show_banners(new)
		-- left alone: into the queue where it is offered (the owner, 2026-11-25; its x in the panel takes it out
		-- again), else nothing changes
		expiry = mp.add_timeout(o.banner_seconds, function()
			expiry = nil
			if queued() then
				choose('queue')
			else
				set_offer(nil)
			end
		end)
	end
	publish()
end

local function play_here(files)
	mp.commandv('loadfile', files[1], 'replace')
	for i = 2, #files do
		mp.commandv('loadfile', files[i], 'append')
	end
end

-- at its end (keep-open) or gone idle there is nothing to lose any more: the offered files play here
on_ended = function(_, value)
	local waiting = offer
	if value and waiting then
		set_offer(nil)
		play_here(waiting.files)
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
		if queuing then
			mp.commandv('script-message-to', 'queue', 'add-files', unpack(files))
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
	-- a new burst: the window chosen for the last one starts now, with what came of it
	start_window()
	queuing = false
	local old = snapshot()
	if old and not same(old.path, files[1]) and launcher and launcher ~= '' then
		set_offer({ old = old, files = files, launcher = launcher })
		return
	end
	set_offer(nil)
	play_here(files)
end

-- here: the offered files in place of what plays; queue: behind it, in the queue;
-- window: the launcher starts a new mpv for them, paused and minimized
-- (mpv-single.exe --paused)
choose = function(choice)
	local taken = offer
	if not taken or not BANNERS[choice] or (choice == 'queue' and not queued()) then
		return
	end
	set_offer(nil)
	if choice == 'here' then
		-- (a late file of its burst is appended here, as it should be)
		play_here(taken.files)
		return
	end
	if choice == 'queue' then
		queuing = true
		mp.commandv('script-message-to', 'queue', 'add-files', unpack(taken.files))
		return
	end
	start_window() -- (a window chosen a moment before, for other files)
	leaving = { files = taken.files, launcher = taken.launcher }
	start_window_later()
end

banners = clicks.new('single-instance-click', BANNERS, choose)

mp.register_script_message('open', open)
-- a banner's click without a pointer (tests): here, queue or window
mp.register_script_message('choose', choose)

publish()
