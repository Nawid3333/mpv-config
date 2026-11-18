-- faststream-quality.lua - the one Quality button and menu: the qualities this video comes in (the page's list,
-- else the stream's own variants), switched without losing the position.

local mp = require('mp')
local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')
local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))

local opts = {
	-- the tests' local clips: entries without a scheme are taken too
	test_local = false,
}
options.read_options(opts, 'faststream_quality')

-- the fragment item the FastStream host appends the qualities list under
local QUALITY_MARKER = 'fs-quality='
local MENU_TYPE = 'faststream-quality'

local script_name = mp.get_script_name()

local state = {
	path = nil, -- the current file's path, nil while nothing is loaded
	list = nil, -- the entries offered, nil without a choice
	source = nil, -- where the list came from: 'page', 'editions' or 'tracks'
	current = nil, -- 1-based index of the playing entry, nil when none matches
}

-- The file's own qualities (editions or tracks), read once it has loaded. They stay
-- between two files, as the page's list does (a relayout of the bar each time), until
-- the next file has loaded or mpv is idle; a row picked in between does nothing.
local loaded = false
local variants = nil -- {source = 'editions' | 'tracks', list = {...}, current = index}
local back_to = nil -- {time, path}: where an HLS switch's restart returns to (choose)
local back_wait = nil -- the timer of that way back, once the restart is done
local seeks = 0 -- seek events so far: a newer one than the restart's means the user seeked

local function publish_returning()
	mp.set_property_native('user-data/faststream-quality/returning', back_to ~= nil or back_wait ~= nil)
end

-- The first n whole characters of a UTF-8 string (labels come from web pages; LuaJIT has no utf8 library).
---@param s string
---@param n integer
---@return string
local function utf8_prefix(s, n)
	local out = {}
	for char in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
		if #out == n then
			break
		end
		out[#out + 1] = char
	end
	return table.concat(out)
end

---@param s string
---@return string
local function url_decode(s)
	return (s:gsub('%%(%x%x)', function(code)
		return string.char(tonumber(code, 16))
	end))
end

--- The value of the last whole `marker` item of the URL fragment, or nil (faststream-fragment.lua).
---@param url string
---@param marker string
---@return string|nil
local function fragment_value(url, marker)
	local value = fragment.value(url, marker)
	return value ~= '' and value or nil
end

---@param path string
---@return string
local function path_without_fragment(path)
	local hash = path:find('#', 1, true)
	return hash and path:sub(1, hash - 1) or path
end

--- One entry {label, height, url}, or nil: http(s) only (the list comes from a web page); local paths with test_local.
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
		value = raw.url,
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

--- The index of the entry this path plays (its url is the path up to the first '#'); none: no active row, no badge.
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

--- "720p", or "1080p60": a rate above 30 is named, as web players do.
---@param height integer
---@param fps number
---@return string
local function variant_label(height, fps)
	local rate = math.floor(fps + 0.5)
	return height .. 'p' .. (rate > 30 and tostring(rate) or '')
end

--- One row per label, highest first: the variant playing, else the highest bitrate, else the first; nil below two.
---@param found table[] {label, height, fps, bitrate, playing, value, edition | track}
---@return table|nil, integer|nil
local function variant_rows(found)
	local by_label, labels = {}, {}
	for _, v in ipairs(found) do
		local kept = by_label[v.label]
		if not kept then
			by_label[v.label] = v
			labels[#labels + 1] = v.label
		elseif not kept.playing and (v.playing or v.bitrate > kept.bitrate) then
			by_label[v.label] = v
		end
	end
	if #labels < 2 then
		return nil, nil
	end
	local rows = {}
	for _, label in ipairs(labels) do
		rows[#rows + 1] = by_label[label]
	end
	-- labels are unique, so two rows of one height differ in their named rate
	table.sort(rows, function(a, b)
		if a.height ~= b.height then
			return a.height > b.height
		end
		return a.fps > b.fps
	end)
	local current = nil
	for i, row in ipairs(rows) do
		if row.playing then
			current = i
		end
		row.playing, row.bitrate, row.fps = nil, nil, nil -- only the menu's fields are published
	end
	return rows, current
end

---@param tracks table[]
---@return table|nil
local function playing_video(tracks)
	for _, track in ipairs(tracks) do
		if track.type == 'video' and track.selected then
			return track
		end
	end
	return nil
end

---@param tracks table[]
---@return table|nil, integer|nil
local function edition_variants(tracks)
	local editions = mp.get_property_native('edition-list')
	if type(editions) ~= 'table' or #editions < 2 then
		return nil, nil
	end
	-- editions made from programs (HLS variants, YouTube's formats); a Matroska file's
	-- editions are cuts of a film, and its tracks belong to no program
	local video = playing_video(tracks)
	local programs = video and video['program-ids']
	if type(programs) ~= 'table' or #programs == 0 then
		return nil, nil
	end
	local playing = mp.get_property_number('current-edition')
	local found = {}
	for _, edition in ipairs(editions) do
		local title = type(edition.title) == 'string' and edition.title or ''
		local height = tonumber(title:match('%d+x(%d+)'))
		local id = tonumber(edition.id)
		if height and height > 0 and id then
			local metadata = type(edition.metadata) == 'table' and edition.metadata or {}
			-- the codec's rate ("60 fps"), else yt-dlp's after the height ("(1080p60)"), which
			-- mpv's EDL editions carry in their title
			local fps = tonumber(title:match('([%d%.]+) fps'))
				or tonumber(title:match('[^%d]' .. height .. 'p(%d+)'))
				or 0
			found[#found + 1] = {
				label = variant_label(height, fps),
				height = height,
				fps = fps,
				bitrate = tonumber(metadata.variant_bitrate) or 0,
				playing = id == playing,
				edition = id,
				value = 'edition:' .. id,
			}
		end
	end
	return variant_rows(found)
end

--- The video tracks as qualities (variants mpv lists as tracks); cover art and other pictures are none.
---@param tracks table[]
---@return table|nil, integer|nil
local function track_variants(tracks)
	local found = {}
	for _, track in ipairs(tracks) do
		local height = tonumber(track['demux-h'])
		local id = tonumber(track.id)
		if track.type == 'video' and not track.image and not track.albumart and height and height > 0 and id then
			local fps = tonumber(track['demux-fps']) or 0
			found[#found + 1] = {
				label = variant_label(height, fps),
				height = height,
				fps = fps,
				bitrate = tonumber(track['hls-bitrate']) or tonumber(track['demux-bitrate']) or 0,
				playing = track.selected == true,
				track = id,
				value = 'track:' .. id,
			}
		end
	end
	return variant_rows(found)
end

local function read_variants()
	local tracks = mp.get_property_native('track-list') or {}
	local list, current = edition_variants(tracks)
	local source = 'editions'
	if not list then
		list, current = track_variants(tracks)
		source = 'tracks'
	end
	variants = list and { source = source, list = list, current = current } or nil
end

local pushed_json = nil -- the button JSON uosc last got

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

---@param entry table
---@return string|nil
local function hint_for(entry)
	if entry.height > 0 and not entry.label:find(entry.height .. 'p', 1, true) then
		return entry.height .. 'p'
	end
	return nil
end

--- Opens the menu, or with `update` refreshes it while it is open (the active row after
--- a switch, the next file's list); a file without a choice closes it.
---@param update boolean|nil
local function open_menu(update)
	if update and mp.get_property_native('user-data/uosc/menu/type') ~= MENU_TYPE then
		return
	end
	if not state.list then
		if update then
			mp.commandv('script-message-to', 'uosc', 'close-menu', MENU_TYPE)
		end
		return -- no choice for this file: nothing to open
	end
	local items = {}
	for i, entry in ipairs(state.list) do
		items[#items + 1] = {
			title = entry.label,
			hint = hint_for(entry),
			active = i == state.current,
			value = entry.value, -- back as the activate event's value
		}
	end
	local json, err = utils.format_json({
		type = MENU_TYPE,
		title = 'Quality',
		items = items,
		-- uosc's callback menu mode: every menu event arrives at 'menu-callback' instead of uosc running item values.
		callback = { script_name, 'menu-callback' },
	})
	if json then
		if update then
			mp.commandv('script-message-to', 'uosc', 'update-menu', json)
		else
			mp.commandv('script-message-to', 'uosc', 'open-menu', json)
		end
	else
		msg.error('quality menu JSON: ' .. tostring(err))
	end
end

-- A push uosc did not get is sent again every second until it has it, as faststream-episodes.lua does.
local retry = nil
local recompute -- below
local function retry_until_delivered(delivered)
	if delivered then
		if retry then
			retry:kill()
			retry = nil
			-- uosc has only just started: a push in its first moment can come before it
			-- listens (the reason for the 0.5 s push below), so once more a second later
			mp.add_timeout(1, function()
				pushed_json = nil
				recompute()
			end)
		end
	elseif not retry then
		retry = mp.add_periodic_timer(1, function()
			recompute()
		end)
	end
end

local menu_shows = nil -- the list and current the open menu was last given, as JSON

-- Picks the list for the current path (the page's, else the file's own), publishes it for
-- the tests, pushes the button, sets the disposition flags and updates an open menu.
function recompute()
	local list, current, source = nil, nil, nil
	if state.path then
		list = quality_list(state.path)
		if list then
			current, source = playing_index(state.path, list), 'page'
		elseif variants then
			list, current, source = variants.list, variants.current, variants.source
		end
	end
	state.list, state.current, state.source = list, current, source

	mp.set_property_native('user-data/faststream-quality/list', state.list)
	mp.set_property_native('user-data/faststream-quality/source', state.source)
	mp.set_property_native('user-data/faststream-quality/current', state.current)

	local data = {
		icon = 'high_quality',
		tooltip = 'Quality',
		command = { 'script-message-to', mp.get_script_name(), 'open-menu' },
		menu_command = { 'script-message-to', mp.get_script_name(), 'open-menu' },
		hide = list == nil,
	}
	if list and current then
		-- uosc badges stay short: a variant's frame rate does not fit beside its height, so the height alone.
		local entry = list[current]
		local label = (not entry.url and #entry.label > 5) and (entry.height .. 'p') or entry.label
		data.badge = utf8_prefix(label, 5)
	end
	mp.set_property_native('user-data/faststream-quality/button', data) -- for the tests
	local sent = push_button(data)
	-- nothing to show: no button to bring to a uosc that is not there
	retry_until_delivered(sent or list == nil)
	-- The dispositions' flags: true only for a button uosc has got; always a boolean (a deleted key tells no observer).
	local shown = list ~= nil and sent
	mp.set_property_native('user-data/faststream-quality/shown', shown)
	mp.set_property_native('user-data/faststream-quality/editions', shown and source == 'editions')

	local shows = utils.format_json({ state.list or false, state.current or false })
	if shows ~= menu_shows then
		menu_shows = shows
		open_menu(true)
	end
end

--- The path's fragment, '#' first, byte for byte: what a switch carries to the next file.
---@param path string|nil
---@return string
local function path_fragment(path)
	if not path then
		return ''
	end
	local hash = path:find('#', 1, true)
	return hash and path:sub(hash) or ''
end

--- Loads the page's file `entry` from where the video is.
---@param entry table
local function switch_file(entry)
	-- the request headers and title the stream came with: without them a CDN that checks Referer refuses the next file
	local file_options = fragment.reopen_options()
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
	-- a delay the user set for this video: auto-start.lua puts both back to 0 when a file
	-- unloads, and a per-file option is applied after that
	for _, name in ipairs({ 'sub-delay', 'audio-delay' }) do
		local delay = mp.get_property_number(name) or 0
		if delay ~= 0 then
			file_options[name] = tostring(delay)
		end
	end
	local url = entry.url .. path_fragment(state.path)
	if mp.get_property_native('pause') then
		file_options['pause'] = 'yes'
		-- auto-start.lua unpauses every new file; this one is the paused file in another quality, so it stays paused
		mp.set_property_native('user-data/auto-start/keep-pause', url)
	end
	mp.set_property_native('user-data/faststream-quality/last-load', { url = url, options = file_options })
	-- named arguments: loadfile's options come after its index (mpv 0.38+)
	local loaded, err = mp.command_native({
		name = 'loadfile',
		url = url,
		flags = 'replace',
		index = -1,
		options = file_options,
	})
	-- a refused loadfile (an option mpv does not take) only says so here (checklist 3)
	if loaded == nil then
		msg.warn('could not open ' .. url .. ': ' .. tostring(err))
		mp.commandv(
			'script-message-to',
			'notify',
			'show',
			'faststream-quality',
			'Quality not switched',
			tostring(err),
			'4'
		)
	end
end

--- Plays the row with this value; the playing row, one not in the list, or any while a file loads: nothing.
---@param value string
local function choose(value)
	local list = state.list or {}
	local index = nil
	for i, entry in ipairs(list) do
		if entry.value == value then
			index = i
			break
		end
	end
	local entry = index and list[index]
	-- while a file loads (a switch's own, the next episode) the position is not known yet:
	-- a pick then would replace that load and start from the beginning
	if not entry or index == state.current or not loaded then
		return
	end
	if entry.url then
		switch_file(entry)
		return
	end
	-- file-local, as the edition: a track id is this file's own, and `vid` itself stays
	-- for the next file with the same tracks (mpv's track-list fingerprint)
	local time = mp.get_property_number('time-pos')
	local switched
	if entry.edition then
		switched = mp.commandv('set', 'file-local-options/edition', tostring(entry.edition))
	else
		switched = mp.commandv('set', 'file-local-options/vid', tostring(entry.track))
	end
	if not switched then
		msg.warn('could not switch to ' .. entry.label)
		return
	end
	-- An HLS variant starts over from the beginning: mpv restarts playback on an edition change for a format whose
	-- timestamps may reset; `seeking` right after the switch says so (EDL and track switches send none).
	if time and time >= 1 and mp.get_property_native('seeking') then
		back_to = { time = time, path = state.path }
		publish_returning()
	end
end

-- A seek while that restart is pending is the user's (the switch itself sends no seek
-- event, measured): it wins, and the restart it ends is not the switch's.
mp.register_event('seek', function()
	back_to = nil
	seeks = seeks + 1
	publish_returning()
end)

-- The restart is done: back to where the video was, a moment later and only when no user seek came meanwhile.
mp.register_event('playback-restart', function()
	local back = back_to
	back_to = nil
	if not back or back.path ~= state.path then
		publish_returning()
		return
	end
	local before = seeks
	back_wait = mp.add_timeout(0.1, function()
		back_wait = nil
		if seeks == before and not back_to and not mp.get_property_native('seeking') and back.path == state.path then
			local now = mp.get_property_number('time-pos')
			if now and now < back.time - 1 then
				mp.commandv('seek', tostring(back.time), 'absolute')
			end
		end
		publish_returning()
	end)
	publish_returning()
end)

mp.register_script_message('menu-callback', function(json)
	local event = utils.parse_json(json)
	if type(event) ~= 'table' then
		return
	end
	if event.type == 'activate' and type(event.value) == 'string' then
		choose(event.value)
	end
end)

mp.register_script_message('open-menu', function()
	open_menu(false)
end)

-- Read again here: the same path loaded again after an end-file (which clears it)
-- is no change of `path`, and its observer stays silent.
mp.register_event('file-loaded', function()
	state.path = mp.get_property('path')
	loaded = true
	read_variants()
	recompute()
end)

mp.register_event('end-file', function()
	loaded = false
	back_to = nil
	if back_wait then
		back_wait:kill()
		back_wait = nil
	end
	publish_returning()
end)

-- The fragment comes with `path`, known before the file loads: the button is ready as
-- soon as the address is.
mp.observe_property('path', 'string', function(_, path)
	if path then
		state.path = path
		recompute()
	end
end)

-- A switch, and tracks or editions that come later: the badge and the menu follow.
local function on_variants_change()
	if loaded then
		read_variants()
		recompute()
	end
end
mp.observe_property('track-list', 'native', on_variants_change)
mp.observe_property('edition-list', 'native', on_variants_change)
mp.observe_property('current-edition', 'native', on_variants_change)

-- Between two files the last path stays (a quality switch, the next episode): hiding and showing the button
-- would repaint uosc's whole UI twice. file-loaded reads the next file's path; idle clears it.
mp.observe_property('idle-active', 'bool', function(_, idle)
	if idle then
		state.path = nil
		variants = nil
		recompute()
	end
end)

-- as the other managed buttons: uosc may start after this script, and the first push
-- may have gone into the void before uosc listened, so it is sent once more
mp.add_timeout(0.5, function()
	pushed_json = nil
	recompute()
end)
