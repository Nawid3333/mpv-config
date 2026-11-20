-- source-info.lua - the uosc "source" toolbar button: where the video comes
-- from, and every link it can know, ready to copy or open.

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')
local options = require('mp.options')
local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))

local opts = { launch = true }
options.read_options(opts, 'source_info')

local PAGE_MARKER = 'fs-page='

local state = {
	path = nil, -- mpv's `path` for the current file
	opened = nil, -- the URL mpv actually opened (stream-open-filename at load)
	origin = nil, -- the command-line URL when the ytdl hook rewrote it
	loading = nil, -- `path` from on_load: known for a file that never loads too
}

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

--- "FastStream" / "HLS stream" / "DASH stream" / "stream" / "local file" plus the button badge;
--- nil, nil while nothing is loaded (an idle mpv, between files).
---@return string|nil long, string|nil short
local function source_of()
	local path = state.path
	if not path then
		return nil, nil
	end
	if fragment_value(path, 'fs-content=') or fragment_value(path, 'fs-id=') or fragment_value(path, PAGE_MARKER) then
		return 'FastStream', 'Fast'
	end
	if path:find('://', 1, true) then
		local ff = mp.get_property('file-format') or ''
		if ff == 'hls' or ff == 'dash' then
			return ff:upper() .. ' stream', 'Strm'
		end
		return 'stream', 'Strm'
	end
	return 'local file', 'File'
end

--- A URL without the helper's fs-* fragment items, not decoded: %2B and %26 inside a signed token are part of it.
---@param url string
---@return string
local function without_fs_tags(url)
	local hash = url:find('#', 1, true)
	if not hash then
		return url
	end
	local kept = {}
	for _, item in ipairs(fragment.items(url)) do
		if item ~= '' and not item:find('^fs%-') then
			kept[#kept + 1] = item
		end
	end
	return url:sub(1, hash - 1) .. (#kept > 0 and ('#' .. table.concat(kept, '&')) or '')
end

--- The URL mpv opened, or nil for local files - "stream URL" only means URLs. For a stream played from the
--- playlist files FastStream's helper wrote, the stream they stand for (faststream-fragment.lua).
---@return string|nil
local function stream_url()
	if state.opened and state.opened:find('://', 1, true) then
		return state.opened
	end
	local path = fragment.target(state.path) or state.path or ''
	if path:find('://', 1, true) then
		return without_fs_tags(path)
	end
	return nil
end

--- The FastStream page URL behind fs-page=, decoded, when it is a web page.
---@return string|nil
local function page_url()
	local path = state.path or ''
	local value = fragment_value(path, PAGE_MARKER)
	value = value and url_decode(value) or nil
	if value and value:find('^https?://') then
		return value
	end
	return nil
end

---@param value string
local function copy(value)
	-- clipboard/text is what uosc's Ctrl+C copy uses too: there is nothing to fall back on.
	local ok, err = mp.set_property('clipboard/text', value)
	if ok then
		mp.commandv('script-message-to', 'notify', 'show', 'source-copy', 'Copied', value, '4')
	else
		msg.warn('clipboard/text write failed (' .. tostring(err) .. ')')
		mp.commandv('script-message-to', 'notify', 'show', 'source-copy', 'Copy failed', tostring(err), '4')
	end
end

local last_button_json = nil

local function update_button()
	local data = {
		icon = 'language',
		-- the SHORT name (second result): a call as a table field keeps only
		-- its first result, which is wider than the button
		badge = select(2, source_of()),
		tooltip = 'Source: click for links (copy / open)',
		command = { 'script-message-to', mp.get_script_name(), 'open-menu' },
		menu_command = { 'script-message-to', mp.get_script_name(), 'open-menu' },
	}
	mp.set_property_native('user-data/source-info/badge', data.badge or '') -- for the tests
	local json = utils.format_json(data)
	if json and json ~= last_button_json then
		last_button_json = json
		mp.commandv('script-message-to', 'uosc', 'set-button', 'source', json)
	end
end

---@return string|nil
local function origin_or_nil()
	if state.origin and (state.path or ''):find('://', 1, true) then
		return state.origin
	end
	return nil
end

--- One link entry: a parent row ("Copy" on the row, actions beside it).
---@param title string
---@param hint string
---@param icon string
---@param url string
---@param commands {title: string, icon: string, value: string}[]
---@return table
local function link_item(title, hint, icon, url, commands)
	return {
		title = title,
		hint = hint ~= '' and hint or nil,
		icon = icon,
		value = 'copy:' .. url, -- Ctrl+C on the selected row copies the URL
		keep_open = true,
		align = 'left',
		items = commands,
	}
end

--- The menu's rows for state.path, and the links behind them.
---@return table[] items, string|nil stream, string|nil origin, string|nil page
local function menu_items()
	local items = {}

	local stream = stream_url()
	-- Played from the helper's playlist files: a temp file to no one, and a stream mpv cannot open by its
	-- address alone (that is why the helper wrote them), so the stream is only copied.
	local package = fragment.target(state.path) ~= nil
	if stream then
		-- Opened again with the FastStream tags, so Auto upscale and resume still
		-- know it; copied without them.
		local reopen = state.opened or state.path or stream
		local commands = { { title = 'Copy', icon = 'content_copy', value = 'copy:' .. stream } }
		if not package then
			commands[#commands + 1] = { title = 'Open in mpv', icon = 'play_arrow', value = 'open:' .. reopen }
		end
		items[#items + 1] = link_item('Stream URL', 'what mpv is playing', 'link', stream, commands)
	end
	local origin = origin_or_nil()
	if origin and origin ~= stream then
		items[#items + 1] = link_item('Original URL', 'the page it came from (ytdl)', 'link', origin, {
			{ title = 'Copy', icon = 'content_copy', value = 'copy:' .. origin },
			{ title = 'Open in browser', icon = 'open_in_browser', value = 'browse:' .. origin },
		})
	end
	local page = page_url()
	if page then
		items[#items + 1] = link_item('Site page', 'the FastStream tab it came from', 'public', page, {
			{ title = 'Copy', icon = 'content_copy', value = 'copy:' .. page },
			{ title = 'Open in browser', icon = 'open_in_browser', value = 'browse:' .. page },
		})
	end
	local local_path = state.path
	if local_path and not package and not local_path:find('://', 1, true) then
		items[#items + 1] = link_item('Local file', 'on disk', 'description', local_path, {
			{ title = 'Copy path', icon = 'content_copy', value = 'copy:' .. local_path },
			{ title = 'Show in directory', icon = 'folder', value = 'show:' .. local_path },
		})
	end
	return items, stream, origin, page
end

local function build_menu()
	local items, stream, origin, page = menu_items()
	mp.set_property_native('user-data/source-info/links', { stream = stream, origin = origin, page = page })

	if #items == 0 then
		items[#items + 1] = { title = 'No links for this file', muted = true, selectable = false, value = '' }
	end

	local script_name = mp.get_script_name()
	local json, err = utils.format_json({
		type = 'source-menu',
		title = source_of() and ('Source: ' .. source_of()) or 'Source',
		items = items,
		-- uosc's callback menu mode: every menu event arrives at 'menu-callback' instead of uosc running item values.
		callback = { script_name, 'menu-callback' },
	})
	if json then
		mp.commandv('script-message-to', 'uosc', 'open-menu', json)
	else
		msg.error('source menu JSON: ' .. tostring(err))
	end
end

local function open_menu()
	build_menu()
end

---@param value string
---@return string verb, string payload
local function split_action(value)
	local verb, payload = value:match('^([%w%-]+):(.*)$')
	return verb or '', payload or ''
end

--- Starts `args` detached, or with source_info-launch=no only records them.
---@param args string[]
local function launch(args)
	if opts.launch then
		-- { args = ... }: mpv's subprocess_detached is commandv('run', unpack(t.args));
		-- a bare array throws
		utils.subprocess_detached({ args = args })
	else
		mp.set_property_native('user-data/source-info/launched', args)
	end
end

--- Opens a web address in the default browser: a plain http(s) URL only, never through cmd
--- (no whitespace, control characters, quotes, < > ^ ` { | } or backslash: browsers percent-encode them).
---@param url string
local function browser_open(url)
	if not url:find('^https?://[^%s%c"<>^`{|}\\]+$') then
		msg.warn('not opening an address that is not a plain http(s) URL: ' .. url)
		mp.commandv('script-message-to', 'notify', 'show', 'source-copy', 'Not opened', 'not a plain web address', '4')
		return
	end
	local platform = mp.get_property('platform') or ''
	if platform == 'windows' then
		-- ShellExecute on the URL, the way Windows opens a link: no shell parses it.
		launch({ 'rundll32.exe', 'url.dll,FileProtocolHandler', url })
	elseif platform == 'darwin' then
		launch({ 'open', url })
	else
		launch({ 'xdg-open', url })
	end
end

--- Shows a folder in the platform's file manager (not Windows: explorer
--- /select, does that there).
---@param dir string
local function folder_open(dir)
	if mp.get_property('platform') == 'darwin' then
		launch({ 'open', dir })
	else
		launch({ 'xdg-open', dir })
	end
end

--- The per-file options a reopened stream needs (headers, title): without them a CDN that checks Referer refuses it.
---@return table|nil options for loadfile, nil when there are none
local function reopen_options()
	local file_options = fragment.reopen_options()
	return next(file_options) and file_options or nil
end

local function handle_activate(value)
	local verb, payload = split_action(value)
	if verb == 'copy' then
		copy(payload)
	elseif verb == 'open' then
		-- named arguments: loadfile's options come after its index (mpv 0.38+)
		local loaded, err = mp.command_native({
			name = 'loadfile',
			url = payload,
			flags = 'replace',
			index = -1,
			options = reopen_options(),
		})
		-- a refused loadfile (an option mpv does not take) only says so here (checklist 3)
		if loaded == nil then
			msg.warn('could not open ' .. payload .. ': ' .. tostring(err))
			mp.commandv('script-message-to', 'notify', 'show', 'source-copy', 'Not opened', tostring(err), '4')
		end
	elseif verb == 'browse' then
		browser_open(payload)
	elseif verb == 'show' then
		if mp.get_property('platform') == 'windows' then
			-- explorer /select,<path> shows the folder with the file selected
			utils.subprocess({ args = { 'explorer', '/select,', payload }, playback_only = false })
		else
			folder_open((utils.split_path(payload)))
		end
	end
end

mp.register_script_message('menu-callback', function(json)
	local event = utils.parse_json(json)
	if type(event) ~= 'table' then
		return
	end
	if event.type == 'activate' and type(event.value) == 'string' then
		handle_activate(event.value)
	elseif
		event.type == 'key'
		and event.id == 'ctrl+c'
		and event.selected_item
		and type(event.selected_item.value) == 'string'
	then
		-- the menu's copy gesture on a selected entry: same value grammar
		local verb, payload = split_action(event.selected_item.value)
		if verb == 'copy' and payload ~= '' then
			copy(payload)
		end
	end
end)

mp.register_script_message('open-menu', open_menu)

-- For the regression test: the links the menu would offer for <path>, without loading it; rows: each row's
-- title and its actions ("Stream URL: Copy, Open in mpv").
mp.register_script_message('links-for', function(path)
	local saved = state
	state = { path = path }
	local items, stream, _, page = menu_items()
	local rows = {}
	for _, item in ipairs(items) do
		local actions = {}
		for _, command in ipairs(item.items or {}) do
			actions[#actions + 1] = command.title
		end
		rows[#rows + 1] = item.title .. ': ' .. table.concat(actions, ', ')
	end
	mp.set_property_native('user-data/source-info/links-for', { stream = stream, page = page, rows = rows })
	state = saved
end)

mp.register_event('file-loaded', function()
	state.path = mp.get_property('path')
	update_button()
end)

-- Both sides of the ytdl hook's rewrite of stream-open-filename; priority 11 runs after ytdl_hook's on_load (10).
-- Only a web address counts as opened: yt-dlp's edl:// or memory:// is none, so the pasted link stays the stream URL.
mp.add_hook('on_load', 11, function()
	local path = mp.get_property('path') or ''
	state.loading = path
	local opened = mp.get_property('stream-open-filename') or ''
	if path:find('://', 1, true) and opened ~= path and opened:find('^https?://') then
		state.opened = opened
		state.origin = path
	end
end)

-- A FastStream stream that does not open (403, 404, an expired token): say what happened and what helps.
---@param event {reason: string, file_error: string|nil}
local function announce_failure(event)
	local path = state.loading or ''
	if
		event.reason ~= 'error'
		or not (
			fragment_value(path, 'fs-content=')
			or fragment_value(path, 'fs-id=')
			or fragment_value(path, PAGE_MARKER)
		)
	then
		return
	end
	mp.commandv(
		'script-message-to',
		'notify',
		'show',
		'stream-error',
		'The stream could not be opened',
		'Reload the page in the browser and send it again',
		'10'
	)
	mp.set_property_native('user-data/source-info/failed', { reason = event.file_error or 'error' })
end

mp.register_event('end-file', function(event)
	announce_failure(event)
	state = { path = nil, opened = nil, origin = nil, loading = nil }
	last_button_json = nil
	update_button()
end)

for _, name in ipairs({ 'osd-dimensions' }) do
	mp.observe_property(name, 'native', update_button)
end
