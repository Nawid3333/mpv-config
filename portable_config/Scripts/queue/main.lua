-- queue/main.lua - what plays next, on the user's say: a stream FastStream sends while a window plays ("Add to
-- queue", faststream-offer.lua) or a file opened from Explorer (single-instance.lua) waits right behind the entry
-- that plays, in mpv's own playlist, in the order it came (the panel can change it). Before each one a countdown
-- runs, as FastStream's autoplay counts down before the next episode; Space stops it. A replace of what plays (Play
-- here, the next episode, a file dropped in) keeps the queue: it is put back behind the new entry. The panel bottom
-- right (panel.lua) shows it. Only what was queued counts: autoload's folder files are no queue.

local mp = require('mp')
local utils = require('mp.utils')
local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))

local o = {
	-- the countdown without FastStream's own setting (user-data/faststream/countdown): its default
	countdown_seconds = 5,
	max_items = 50,
}
require('mp.options').read_options(o, 'queue')

local STATE = 'user-data/queue'
-- what FastStream's extension may read (the helper lets it read user-data/faststream/ only): that this mpv queues,
-- and how many wait, so its autoplay leaves an end with a queue to this script
local FASTSTREAM_STATE = 'user-data/faststream/queue'
local COUNTDOWN_SETTING = 'user-data/faststream/countdown'
local MAX_COUNTDOWN = 60

---@class QueueItem
---@field id integer|nil mpv's playlist entry id (nil while it is put back after a replace)
---@field url string what loadfile takes
---@field options table<string, string>|nil per-file options (a stream's headers and title)
---@field title string
---@field detail string
---@field kind string 'stream' or 'file'
---@field added number|nil mp.get_time() when it came
---@field failed boolean|nil it could not be put back after a replace

---@type QueueItem[]
local items = {} -- in their order, which is also their order in the playlist (pin)
local last_ids, last_current = {}, nil -- the playlist as seen last time: entry ids, the current entry's id
local base_keep_open = mp.get_property('keep-open') or 'yes'
local countdown -- {timer, total, left, item}
local stopped_at -- the playlist-pos whose end the user stopped the countdown at
local panel -- (below) panel.lua's handle
local last_added -- {id, at}: the panel marks it for a moment

local function publish()
	local list = {}
	for i, item in ipairs(items) do
		list[i] = { id = item.id, title = item.title, detail = item.detail, kind = item.kind }
	end
	mp.set_property_native(STATE, {
		count = #items,
		items = list,
		countdown = countdown and { seconds = countdown.total, left = countdown.left } or nil,
		added = last_added and last_added.id or nil,
	})
	mp.set_property_native(FASTSTREAM_STATE, { count = #items })
	if panel then
		panel.update(items, countdown, last_added)
	end
end

---@param path string
---@return string
local function file_title(path)
	local name = path:match('[^/\\]+$') or path
	return name:match('^(.+)%.[^.]+$') or name
end

---@param path string
---@return string
local function folder_name(path)
	return path:match('([^/\\]+)[/\\][^/\\]+$') or ''
end

--- The site a stream came from: its page's host (fs-page), else the stream's own.
---@param url string
---@return string
local function site_of(url)
	local tagged = fragment.target(url) or url
	local page = fragment.value(tagged, 'fs-page=')
	if page then
		page = page:gsub('%%(%x%x)', function(hex)
			return string.char(tonumber(hex, 16))
		end)
	end
	local host = (page or tagged):match('^%a[%w+.-]*://([^/?#:]+)')
	return host and host:gsub('^www%.', '') or ''
end

---@return table[] playlist
---@return integer|nil current 1-based index of the current entry
local function playlist()
	local list = mp.get_property_native('playlist') or {}
	for i, entry in ipairs(list) do
		if entry.current then
			return list, i
		end
	end
	return list, nil
end

---@param list table[]
---@param id integer|nil
---@return integer|nil 1-based index
local function index_of(list, id)
	for i, entry in ipairs(list) do
		if entry.id == id then
			return i
		end
	end
end

--- A queued entry is played through mpv's playlist: before the next one mpv must stop at the end, so the countdown
--- can run (keep-open=always holds even before another entry); without a queue the user's own keep-open again.
local function update_keep_open()
	local want = #items > 0 and 'always' or base_keep_open
	if mp.get_property('keep-open') ~= want then
		mp.set_property('file-local-options/keep-open', want)
	end
end

--- Moves the queued entries right behind the current one, in their order: autoload adding a folder's files, the
--- user going back in the playlist, or a put-back entry may have left them elsewhere.
local function pin()
	local list, current = playlist()
	if not current then
		return
	end
	for k, item in ipairs(items) do
		local at = index_of(list, item.id)
		local want = current + k
		if at and at ~= want then
			-- playlist-move takes the place of the entry at its second index: one further when moving down
			mp.commandv('playlist-move', at - 1, at > want and want - 1 or want)
			list, current = playlist()
			if not current then
				return
			end
		end
	end
end

--- Loads an item into the playlist at a 0-based index and takes its new entry id.
---@param item QueueItem
---@param index integer
---@return boolean
local function insert(item, index)
	local ok = mp.command_native({
		name = 'loadfile',
		url = item.url,
		flags = 'insert-at',
		index = index,
		options = item.options or {},
	})
	if ok == nil then
		return false
	end
	item.id = mp.get_property_number('playlist/' .. index .. '/id')
	return item.id ~= nil
end

local cancel_countdown -- (below)

--- Follows mpv's playlist: an item that plays now leaves the queue, one the user removed (uosc's playlist) too, and a
--- replace of what plays (every entry gone, a new one current) is undone for the queue: its items go back behind it.
local function sync()
	local list, current = playlist()
	if #list == 0 then
		-- a replace passes through an empty playlist; idle with nothing is handled below (on_idle)
		return
	end
	local ids = {}
	for _, entry in ipairs(list) do
		ids[entry.id] = true
	end
	local current_id = current and list[current].id or nil
	local missing = 0
	for _, item in ipairs(items) do
		if item.id and not ids[item.id] then
			missing = missing + 1
		end
	end
	local replaced = missing > 0
		and missing == #items
		and last_current ~= nil
		and not ids[last_current]
		and current_id ~= nil
		and not last_ids[current_id]
	local kept = {}
	for _, item in ipairs(items) do
		if item.id == current_id then
			-- it plays now: no longer waiting
		elseif item.id and ids[item.id] then
			kept[#kept + 1] = item
		elseif replaced then
			item.id = nil
			kept[#kept + 1] = item
		end
	end
	local changed = #kept ~= #items
	items = kept
	if replaced and current then
		for k, item in ipairs(items) do
			if not insert(item, current + k - 1) then
				item.failed = true
			end
		end
		local alive = {}
		for _, item in ipairs(items) do
			if not item.failed then
				alive[#alive + 1] = item
			end
		end
		items = alive
		list, current = playlist()
		ids = {}
		for _, entry in ipairs(list) do
			ids[entry.id] = true
		end
		changed = true
	end
	last_ids, last_current = ids, current and list[current].id or nil
	pin()
	update_keep_open()
	if changed then
		if countdown and (not items[1] or countdown.item ~= items[1]) then
			cancel_countdown(false)
		end
		publish()
	end
end

---@param item QueueItem
---@return boolean
local function add(item)
	if #items >= o.max_items then
		mp.commandv('script-message-to', 'notify', 'show', 'queue', 'Queue full', o.max_items .. ' are waiting', '3')
		return false
	end
	for _, other in ipairs(items) do
		if other.url == item.url then
			-- already waiting: the panel shows where
			last_added = { id = other.id, at = mp.get_time() }
			publish()
			return false
		end
	end
	local list, current = playlist()
	local index = (current or #list) + #items -- 0-based: behind the current entry and the queue
	if not current and #list == 0 then
		-- nothing loaded: it simply plays
		mp.command_native({ name = 'loadfile', url = item.url, flags = 'replace', options = item.options or {} })
		return true
	end
	item.added = mp.get_time()
	if not insert(item, index) then
		return false
	end
	items[#items + 1] = item
	last_added = { id = item.id, at = item.added }
	last_ids[item.id] = true
	pin()
	update_keep_open()
	publish()
	return true
end

-- FastStream's helper, for "Add to queue": the stream as play would load it, with its per-file options as JSON
-- (headers, title, start, subtitle files, a playlist package's demuxer options).
mp.register_script_message('add-stream', function(url, options_json)
	if type(url) ~= 'string' or url == '' then
		return
	end
	local options = options_json and utils.parse_json(options_json)
	if type(options) ~= 'table' then
		options = {}
	end
	local clean = {}
	for name, value in pairs(options) do
		if type(name) == 'string' and type(value) == 'string' then
			clean[name] = value
		end
	end
	local title = clean['force-media-title']
	add({
		url = url,
		options = clean,
		title = (title and title ~= '') and title or site_of(url),
		detail = site_of(url),
		kind = 'stream',
	})
end)

-- single-instance.lua, for "Add to queue": local files, in the order they were opened
mp.register_script_message('add-files', function(...)
	for _, file in ipairs({ ... }) do
		if file ~= '' then
			add({ url = file, title = file_title(file), detail = folder_name(file), kind = 'file' })
		end
	end
end)

---@param id integer
---@return integer|nil, QueueItem|nil
local function find(id)
	id = tonumber(id)
	for i, item in ipairs(items) do
		if item.id == id then
			return i, item
		end
	end
end

--- Plays a queued item now: the others stay queued behind it.
---@param id integer
local function play_now(id)
	local i, item = find(id)
	if not item then
		return
	end
	table.remove(items, i)
	table.insert(items, 1, item)
	pin()
	local _, current = playlist()
	cancel_countdown(false)
	if current then
		mp.commandv('playlist-play-index', current) -- 0-based: the entry right behind the current one
	end
end

---@param id integer
local function remove(id)
	local i, item = find(id)
	if not item then
		return
	end
	table.remove(items, i)
	local list = playlist()
	local at = index_of(list, item.id)
	if at then
		mp.commandv('playlist-remove', at - 1)
	end
	update_keep_open()
	publish()
end

local function clear()
	local gone = items
	items = {}
	for _, item in ipairs(gone) do
		local at = index_of(playlist(), item.id)
		if at then
			mp.commandv('playlist-remove', at - 1)
		end
	end
	cancel_countdown(false)
	update_keep_open()
	publish()
end

--- Moves a queued item to another place in the queue (1 = next).
---@param id integer
---@param to integer
local function move(id, to)
	local i, item = find(id)
	to = math.floor(tonumber(to) or 0)
	if not item or to < 1 then
		return
	end
	to = math.min(to, #items)
	if to == i then
		return
	end
	table.remove(items, i)
	table.insert(items, to, item)
	pin()
	if countdown and countdown.item ~= items[1] then
		cancel_countdown(false)
	end
	publish()
end

mp.register_script_message('play', play_now)
mp.register_script_message('remove', remove)
mp.register_script_message('clear', clear)
mp.register_script_message('move', move)

--- The countdown's seconds: FastStream's autoplay setting while its helper follows this window, else the default.
---@return integer
local function countdown_seconds()
	local seconds = tonumber(mp.get_property_native(COUNTDOWN_SETTING))
	if not seconds or seconds ~= seconds or seconds < 0 then
		seconds = o.countdown_seconds
	end
	return math.floor(math.min(seconds, MAX_COUNTDOWN))
end

local function show_countdown()
	if not countdown then
		return
	end
	local left = math.max(0, countdown.left)
	mp.commandv(
		'script-message-to',
		'notify',
		'show',
		'queue',
		string.format('Up next in %d s', math.ceil(left)),
		countdown.item.title .. ' (Space: stop)',
		'0',
		tostring(1 - left / countdown.total)
	)
end

---@param stopped boolean the user stopped it: say so
cancel_countdown = function(stopped)
	local was = countdown
	if not was then
		return
	end
	countdown = nil
	was.timer:kill()
	if stopped then
		stopped_at = mp.get_property_number('playlist-pos')
		mp.commandv(
			'script-message-to',
			'notify',
			'show',
			'queue',
			'Up next stopped',
			was.item.title .. ': a click on it in the queue plays it',
			'4'
		)
	else
		mp.commandv('script-message-to', 'notify', 'hide', 'queue')
	end
	publish()
end

local function start_countdown()
	local item = items[1]
	if countdown or not item then
		return
	end
	local seconds = countdown_seconds()
	if seconds == 0 then
		play_now(item.id)
		return
	end
	local tick = 0.25
	countdown = { total = seconds, left = seconds, item = item }
	countdown.timer = mp.add_periodic_timer(tick, function()
		if not countdown then
			return
		end
		countdown.left = countdown.left - tick
		if countdown.left <= 0 then
			local next_item = countdown.item
			cancel_countdown(false)
			play_now(next_item.id)
			return
		end
		show_countdown()
		publish()
	end)
	show_countdown()
	publish()
end

-- The end of what plays, held by keep-open=always while something is queued: the countdown starts. Not again at the
-- end the user stopped it at; leaving the end (a seek back) ends it without a word.
mp.observe_property('eof-reached', 'bool', function(_, ended)
	if ended then
		if #items > 0 and stopped_at ~= mp.get_property_number('playlist-pos') then
			start_countdown()
		end
	else
		cancel_countdown(false)
	end
end)

-- Space and a click on the video (input.conf sends faststream-pause with the pause): as for FastStream's autoplay.
mp.register_script_message('faststream-pause', function()
	if countdown then
		cancel_countdown(true)
	end
end)

mp.register_event('start-file', function()
	stopped_at = nil
	cancel_countdown(false)
end)

mp.observe_property('playlist', 'native', sync)

-- Stopped with nothing left (the playlist cleared, stop): there is nothing to queue behind any more.
mp.observe_property('idle-active', 'bool', function(_, idle)
	if idle and mp.get_property_number('playlist-count', 0) == 0 and #items > 0 then
		items = {}
		last_ids, last_current = {}, nil
		cancel_countdown(false)
		update_keep_open()
		publish()
	end
end)

panel = dofile(mp.get_script_directory() .. '/panel.lua')({
	play = play_now,
	remove = remove,
	clear = clear,
	move = move,
})

publish()
