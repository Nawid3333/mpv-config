-- faststream-quality.lua - the qualities the FastStream web page offered for this
-- video, as a managed uosc button (its badge: the one playing) and a menu that
-- switches between them without losing the position.
--
-- Some sites offer a video as several files, one per quality (360p, 720p, 1080p),
-- and their player loads one. FastStream sends mpv the one its quality setting asks
-- for, and the list: the native host appends it to the stream URL as a fragment item
-- (everything after the first '#', items separated by '&'; a fragment is never sent
-- to the server):
--
--   https://cdn/x.mp4#fs-id=ab12&fs-quality=<percent-encoded JSON>
--
-- The JSON is an array of two to twelve {"label": "720p", "height": 720, "url":
-- "https://host/720.mp4"} (height 0 when the page did not say). The file playing is
-- the entry whose url equals `path` up to its first '#' (the host writes the entries
-- without a fragment of their own). A switch is loadfile replace with the entry's
-- url plus the current fragment, '#' and all items unchanged: the FastStream tags,
-- fs-quality included, travel with the next file, and the button keeps working;
-- with it travel the position (whole seconds, rounded down), the request headers and
-- the title the file came with (reopen_options, as source-info.lua), the host's
-- subtitle paths (options/sub-files) and the pause state.
--
-- Only http(s) entries are ever loaded: the list comes from a web page, and mpv opens
-- local files and UNC paths too. The tests run with
-- script-opts faststream_quality-test_local=yes, which also takes local paths (the
-- clips they name): entries without a scheme and Windows paths, whose drive letter
-- reads as a one-letter scheme (D:\a\...).
--
-- The button is managed: its look is pushed with script-message-to uosc set-button
-- (as the episode buttons and source-info.lua's source button), and uosc.conf's
-- controls= gates it with the disposition <user-data/faststream-quality/shown>, set
-- true only after the first push reached uosc (an uninitialised managed button draws
-- as a question mark) and false once the file carries no valid list or nothing is
-- loaded.
--
-- The menu is a uosc callback menu (source-info.lua's pattern): every event arrives
-- as JSON at our menu-callback, and "activate" carries the entry's 1-based index.
-- input.conf's Video > Quality (FastStream) sends open-menu; a file without a list
-- opens nothing.
--
-- For the tests: user-data/faststream-quality/list (the decoded entries or nothing),
-- .../current (1-based, or nothing), .../shown, .../button (what was last pushed) and
-- .../last-load (the url and options of the last switch).

local mp = require('mp')
local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')

local opts = {
	-- the tests' local clips: entries without a scheme are taken too
	test_local = false,
}
options.read_options(opts, 'faststream_quality')

-- the fragment item the FastStream host appends the qualities list under
local QUALITY_MARKER = 'fs-quality='

local script_name = mp.get_script_name()

local state = {
	path = nil, -- the current file's path, nil while nothing is loaded
	list = nil, -- the file's decoded qualities, nil without a valid list
	current = nil, -- 1-based index of the playing entry, nil when none matches
}

-- ---- reading the fragment -------------------------------------------------------------

---@param s string
---@return string
local function url_decode(s)
	return (s:gsub('%%(%x%x)', function(code)
		return string.char(tonumber(code, 16))
	end))
end

--- The value of the last `marker` item in the fragment part of the URL, or nil.
--- The fragment is everything after the first '#', its items separated by '&'.
--- Only a whole item counts, and the last one wins: the FastStream host drops fs-*
--- items a stream URL already carries and appends its own after the rest, so
--- "xfs-quality=..." can never pass for its tag.
---@param url string
---@param marker string
---@return string|nil
local function fragment_value(url, marker)
	local hash = url:find('#', 1, true)
	if not hash then
		return nil
	end
	local value
	for item in (url:sub(hash + 1) .. '&'):gmatch('([^&]*)&') do
		if item:sub(1, #marker) == marker then
			value = item:sub(#marker + 1)
		end
	end
	return value ~= '' and value or nil
end

---@param path string
---@return string
local function path_without_fragment(path)
	local hash = path:find('#', 1, true)
	return hash and path:sub(1, hash - 1) or path
end

--- One entry {label, height, url} of the list, or nil. http(s) urls only - the list
--- comes from a web page - and with test_local also local paths (no scheme, or a
--- drive letter). A label is
--- always shown, from the height when the page sent none.
---@param raw any
---@return table|nil
local function parse_entry(raw)
	if type(raw) ~= 'table' or type(raw.url) ~= 'string' or raw.url == '' then
		return nil
	end
	local scheme = raw.url:match('^([%a][%w%+%.%-]*):')
	-- a one-letter "scheme" is a drive letter: a local path, as no scheme is
	if scheme and #scheme > 1 then
		scheme = scheme:lower()
		if scheme ~= 'http' and scheme ~= 'https' then
			return nil
		end
	elseif not opts.test_local then
		return nil
	end
	local height = tonumber(raw.height) or 0
	if height < 0 or height ~= math.floor(height) then
		height = 0
	end
	return {
		url = raw.url,
		height = height,
		label = (type(raw.label) == 'string' and raw.label ~= '' and raw.label)
			or (height > 0 and (height .. 'p') or '?'),
	}
end

--- The qualities `path`'s fragment carries, or nil without a valid list: a tag that
--- keeps fewer than two usable entries is no list.
---@param path string
---@return table|nil
local function quality_list(path)
	local raw = fragment_value(path, QUALITY_MARKER)
	if not raw then
		return nil
	end
	local list = utils.parse_json(url_decode(raw))
	if type(list) ~= 'table' or list[1] == nil then
		msg.warn('fs-quality is not a JSON array of qualities')
		return nil
	end
	local entries = {}
	for _, item in ipairs(list) do
		local entry = parse_entry(item)
		if entry then
			entries[#entries + 1] = entry
		else
			msg.warn('fs-quality has an entry without a usable url, left out')
		end
	end
	if #entries < 2 then
		msg.warn('fs-quality keeps fewer than two entries with a usable url')
		return nil
	end
	return entries
end

--- The 1-based index of the entry this path plays: the one whose url is the path up
--- to its first '#'. None when the list does not hold it: the menu stays, without an
--- active row, and the button without a badge.
---@param path string
---@param entries table
---@return number|nil
local function playing_index(path, entries)
	local base = path_without_fragment(path)
	for i, entry in ipairs(entries) do
		if entry.url == base then
			return i
		end
	end
	return nil
end

-- ---- the button -----------------------------------------------------------------------

local pushed_json = nil -- the button JSON uosc last got

--- Sends the button's look to uosc unless it has it already; true when it has.
---@param data table
---@return boolean
local function push_button(data)
	local json, err = utils.format_json(data)
	if not json then
		msg.error('faststream_quality button: ' .. tostring(err))
		return false
	end
	if pushed_json == json then
		return true -- unchanged: uosc's set-button repaints the whole UI every time
	end
	-- remembered only once sent: an update that came while uosc was not up yet has
	-- to be tried again by the next one
	if mp.commandv('script-message-to', 'uosc', 'set-button', 'faststream_quality', json) then
		pushed_json = json
		return true
	end
	return false
end

-- Reads the list and the playing entry for the current path again, publishes both for
-- the tests, pushes the button and sets the disposition flag.
local function recompute()
	local list, current = nil, nil
	if state.path then
		list = quality_list(state.path)
		current = list and playing_index(state.path, list) or nil
	end
	state.list, state.current = list, current

	mp.set_property_native('user-data/faststream-quality/list', state.list)
	mp.set_property_native('user-data/faststream-quality/current', state.current)

	local data = {
		icon = 'high_quality',
		tooltip = 'Quality',
		command = { 'script-message-to', mp.get_script_name(), 'open-menu' },
		menu_command = { 'script-message-to', mp.get_script_name(), 'open-menu' },
		hide = list == nil,
	}
	if current then
		-- uosc badges stay short; the labels are ("1080p"), a longer one is cut
		data.badge = list[current].label:sub(1, 5)
	end
	mp.set_property_native('user-data/faststream-quality/button', data) -- for the tests
	local sent = push_button(data)
	-- The flag uosc.conf's disposition reads: never true for a button uosc has not got,
	-- which it would draw as a question mark.
	mp.set_property_native('user-data/faststream-quality/shown', list ~= nil and sent)
end

-- ---- the menu -------------------------------------------------------------------------

--- The height as a hint beside the row, unless the label says it already.
---@param entry table
---@return string|nil
local function hint_for(entry)
	if entry.height > 0 and not entry.label:find(entry.height .. 'p', 1, true) then
		return entry.height .. 'p'
	end
	return nil
end

local function open_menu()
	if not state.list then
		return -- no list for this file: nothing to open
	end
	local items = {}
	for i, entry in ipairs(state.list) do
		items[#items + 1] = {
			title = entry.label,
			hint = hint_for(entry),
			active = i == state.current,
			value = i, -- the 1-based index, back as the activate event's value
		}
	end
	local json, err = utils.format_json({
		type = 'faststream-quality',
		title = 'Quality',
		items = items,
		-- uosc's callback menu mode (menus.lua): the table is spliced into
		-- "script-message-to <...callback...> <event json>", so every menu event
		-- arrives at our 'menu-callback' instead of uosc running item values as
		-- mpv commands.
		callback = { script_name, 'menu-callback' },
	})
	if json then
		mp.commandv('script-message-to', 'uosc', 'open-menu', json)
	else
		msg.error('quality menu JSON: ' .. tostring(err))
	end
end

-- ---- switching ------------------------------------------------------------------------

--- The path's fragment, '#' first, byte for byte: what a switch carries to the next file.
---@param path string|nil
---@return string
local function path_fragment(path)
	local hash = path and path:find('#', 1, true)
	return hash and path:sub(hash) or ''
end

--- The per-file options the stream came with: its request headers and its title. The
--- FastStream host hands them over as per-file options of the one file (loadfile's
--- options), so a plain `loadfile <url> replace` opened the next file without them: no
--- Referer/Origin/User-Agent, which a CDN that checks them refuses. mpv's list syntax:
--- ',' separates the items, '\,' is a comma inside one, and an item ending in '\'
--- would swallow the separator after it (left out, as the host does).
---@return table options for loadfile
local function reopen_options()
	local file_options, fields = {}, {}
	for _, field in ipairs(mp.get_property_native('http-header-fields') or {}) do
		if type(field) == 'string' and field ~= '' and field:sub(-1) ~= '\\' then
			fields[#fields + 1] = (field:gsub(',', '\\,'))
		end
	end
	if #fields > 0 then
		file_options['http-header-fields'] = table.concat(fields, ',')
	end
	local title = mp.get_property('options/force-media-title') or ''
	if title ~= '' then
		file_options['force-media-title'] = title
	end
	return file_options
end

--- Plays the entry at `index` from where the video is. The playing entry does nothing.
---@param index number
local function choose(index)
	local entry = state.list and state.list[index]
	if not entry or index == state.current then
		return
	end
	local file_options = reopen_options()
	local time = mp.get_property_number('time-pos')
	if time and time >= 1 then
		-- a whole second, down: a switch in the middle of one restarts there
		file_options['start'] = tostring(math.floor(time))
	end
	-- the host hands subtitles along as a per-file path list
	local subs = mp.get_property('options/sub-files')
	if subs and subs ~= '' then
		file_options['sub-files'] = subs
	end
	if mp.get_property_native('pause') then
		file_options['pause'] = 'yes'
	end
	local url = entry.url .. path_fragment(state.path)
	mp.set_property_native('user-data/faststream-quality/last-load', { url = url, options = file_options })
	-- named arguments: loadfile's options come after its index (mpv 0.38+)
	mp.command_native({
		name = 'loadfile',
		url = url,
		flags = 'replace',
		index = -1,
		options = file_options,
	})
end

-- With `callback` set, uosc sends every menu event here as JSON (see
-- uosc/lib/menus.lua open_command_menu's callback path).
mp.register_script_message('menu-callback', function(json)
	local event = utils.parse_json(json)
	if type(event) ~= 'table' then
		return
	end
	if event.type == 'activate' and type(event.value) == 'number' then
		choose(event.value)
	end
end)

mp.register_script_message('open-menu', open_menu)

-- ---- state per file -------------------------------------------------------------------

-- Read again here: the same path loaded again after an end-file (which clears it)
-- is no change of `path`, and its observer stays silent.
mp.register_event('file-loaded', function()
	state.path = mp.get_property('path')
	recompute()
end)

-- The fragment comes with `path`, known before the file loads: the button is ready as
-- soon as the address is.
mp.observe_property('path', 'string', function(_, path)
	if path then
		state.path = path
		recompute()
	end
end)

-- The old file's end clears everything (the button hides between the files), and so
-- does idle.
mp.register_event('end-file', function()
	state.path = nil
	recompute()
end)

mp.observe_property('idle-active', 'bool', function(_, idle)
	if idle then
		state.path = nil
		recompute()
	end
end)

-- as the other managed buttons: uosc may start after this script, and the first push
-- may have gone into the void before uosc listened, so it is sent once more
mp.add_timeout(0.5, function()
	pushed_json = nil
	recompute()
end)
