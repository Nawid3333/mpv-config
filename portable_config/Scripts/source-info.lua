-- source-info.lua - the uosc "source" toolbar button: where the video comes
-- from, and every link it can know, ready to copy or open.
--
-- 2026-09-29, at the user's request: "a button in the UI like faststream so I
-- can see the source and stream links and also the site link when it comes
-- from Firefox FastStream so I can also copy it and open it in browser".
--
-- uosc.conf's controls= carries "button:source" (a managed button; we push
-- its look via script-message-to uosc set-button, the same pattern as
-- speed-button.lua and gpu-toggles.lua's upscale button).
--
-- What can be known, and how (none of it is guessed):
--   stream URL  = the URL mpv opened. The ytdl hook rewrites
--                 stream-open-filename during on_load, so for a web page
--                 `path` (the command-line URL) and the opened media URL
--                 differ - both are offered then.
--   site page   = the FastStream native host appends `#fs-page=<percent-
--                 encoded page URL>` to each stream URL it hands mpv (same
--                 fragment family as fs-content= / fs-id=; the part after #
--                 is a URL fragment, never sent to the CDN). Written by the
--                 FastStream fork's faststream-mpv-host.mjs; until the fork
--                 ships a release with it, this entry stays absent and the
--                 rest of the button still works.
--   local file  = the full path ("Show in directory", "Copy path").
--
-- Copying: each entry has a "Copy" sub-item, and uosc's menu selects items
-- with arrows and copies the selected one with Ctrl+C - the actions below
-- report whatever the selected entry's value carries. Copying goes through
-- mpv's clipboard/text property (this build ships the Windows clipboard
-- backend; the manual marks the property RW). There is no script-message
-- fallback: uosc's own copy path uses the same property (plus its ziggy
-- helper binary, which only uosc's process can call), so when the property
-- is missing the user gets a failure banner instead of a silent no-op.
--
-- Opening: a stream URL re-opens it in THIS player (loadfile replace; the
-- player instance keeps its cache warm and its own resume state); a site URL
-- opens in the default browser (Windows `rundll32 url.dll,FileProtocolHandler`,
-- macOS `open`, else xdg-open). Explorer is asked to select the local file,
-- like uosc's own "Show in directory".
--
-- Never through cmd (2026-10-02): `cmd /c start "" <url>` ran whatever
-- followed an unquoted '&' in the address as a command of its own (mpv quotes
-- an argument only when it holds a space or a quote), and the site page
-- address comes from the website. Only a plain http(s) address is opened.
--
-- script-opts: source_info-launch=no records what would be launched in
-- user-data/source-info/launched instead of launching it (the regression test).

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')
local options = require('mp.options')

local opts = { launch = true }
options.read_options(opts, 'source_info')

local PAGE_MARKER = 'fs-page='

local state = {
	path = nil, -- mpv's `path` for the current file
	opened = nil, -- the URL mpv actually opened (stream-open-filename at load)
	origin = nil, -- the command-line URL when the ytdl hook rewrote it
	loading = nil, -- `path` from on_load: known for a file that never loads too
}

-- ---- finding the links ------------------------------------------------------------

---@param s string
---@return string
local function url_decode(s)
	return (s:gsub('%%(%x%x)', function(code)
		return string.char(tonumber(code, 16))
	end))
end

--- The value of the last `marker` item in the fragment part of the URL, or
--- nil. The fragment is everything after the first '#', its items separated
--- by '&'. Only a whole item counts, and the last one wins: the FastStream
--- host drops fs-* items a stream URL already carries and appends its own
--- after the rest, so "xfs-page=..." (or anything else a stream URL brings)
--- can never pass for its tag.
---@param url string
---@param marker string
---@return string|nil
local function fragment_value(url, marker)
	-- Only the fragment: a marker-looking query parameter in the page's own
	-- URL must not be readable as ours (the host writes its markers into the
	-- fragment only).
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

--- "FastStream" / "HLS stream" / "stream" / "local file" plus the button badge.
---@return string long, string short
local function source_of()
	local path = state.path or ''
	if path:find('fs-content=', 1, true) or path:find('fs-id=', 1, true) or path:find('fs-page=', 1, true) then
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

--- A URL without the FastStream host's fs-* fragment items (and without the
--- '#' when nothing else is left): what was really requested, as another player
--- or the browser needs it. Not decoded: %2B and %26 inside a signed token or a
--- proxied address are part of it (decoding them broke the copied link,
--- 2026-10-02).
---@param url string
---@return string
local function without_fs_tags(url)
	local hash = url:find('#', 1, true)
	if not hash then
		return url
	end
	local kept = {}
	for item in (url:sub(hash + 1) .. '&'):gmatch('([^&]*)&') do
		if item ~= '' and not item:find('^fs%-') then
			kept[#kept + 1] = item
		end
	end
	return url:sub(1, hash - 1) .. (#kept > 0 and ('#' .. table.concat(kept, '&')) or '')
end

--- The URL mpv opened, or nil for local files - "stream URL" only means URLs.
---@return string|nil
local function stream_url()
	if state.opened and state.opened:find('://', 1, true) then
		return state.opened
	end
	local path = state.path or ''
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

-- ---- copying ----------------------------------------------------------------------

---@param value string
local function copy(value)
	-- clipboard/text is RW in this build (Windows clipboard backend); uosc's
	-- Ctrl+C menu copy uses the same property, so no second mechanism exists
	-- to fall back on from another script.
	local ok, err = mp.set_property('clipboard/text', value)
	if ok then
		mp.commandv('script-message-to', 'notify', 'show', 'source-copy', 'Copied', value, '4')
	else
		msg.warn('clipboard/text write failed (' .. tostring(err) .. ')')
		mp.commandv('script-message-to', 'notify', 'show', 'source-copy', 'Copy failed', tostring(err), '4')
	end
end

-- ---- the button -------------------------------------------------------------------

local last_button_json = nil

local function update_button()
	local data = {
		icon = 'language',
		-- the SHORT name: a call as a table field keeps only its first
		-- result, which put "local file"/"FastStream" on the badge, wider
		-- than the button (until 2026-10-02)
		badge = select(2, source_of()),
		tooltip = 'Source: click for links (copy / open)',
		command = { 'script-message-to', mp.get_script_name(), 'open-menu' },
		menu_command = { 'script-message-to', mp.get_script_name(), 'open-menu' },
	}
	local json = utils.format_json(data)
	if json and json ~= last_button_json then
		last_button_json = json
		mp.commandv('script-message-to', 'uosc', 'set-button', 'source', json)
	end
end

-- ---- the menu ---------------------------------------------------------------------

--- The command-line URL when the ytdl hook rewrote the stream (state.origin).
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

local function build_menu()
	local items = {}

	local stream = stream_url()
	if stream then
		-- Opened again with the FastStream tags, so Auto upscale and resume still
		-- know it; copied without them.
		local reopen = state.opened or state.path or stream
		items[#items + 1] = link_item('Stream URL', 'what mpv is playing', 'link', stream, {
			{ title = 'Copy', icon = 'content_copy', value = 'copy:' .. stream },
			{ title = 'Open in mpv', icon = 'play_arrow', value = 'open:' .. reopen },
		})
	end
	local origin = origin_or_nil()
	if origin and origin ~= stream then
		items[#items + 1] = link_item('Original URL', 'the page it came from (ytdl)', 'link', origin, {
			{ title = 'Copy', icon = 'content_copy', value = 'copy:' .. origin },
			{ title = 'Open in browser', icon = 'open_in_browser', value = 'browse:' .. origin },
		})
	end
	local page = page_url()
	-- What the menu offers, for the regression test.
	mp.set_property_native('user-data/source-info/links', { stream = stream, origin = origin, page = page })
	if page then
		items[#items + 1] = link_item('Site page', 'the FastStream tab it came from', 'public', page, {
			{ title = 'Copy', icon = 'content_copy', value = 'copy:' .. page },
			{ title = 'Open in browser', icon = 'open_in_browser', value = 'browse:' .. page },
		})
	end
	local local_path = state.path
	if local_path and not local_path:find('://', 1, true) then
		items[#items + 1] = link_item('Local file', 'on disk', 'description', local_path, {
			{ title = 'Copy path', icon = 'content_copy', value = 'copy:' .. local_path },
			{ title = 'Show in directory', icon = 'folder', value = 'show:' .. local_path },
		})
	end

	if #items == 0 then
		items[#items + 1] = { title = 'No links for this file', muted = true, selectable = false, value = '' }
	end

	local script_name = mp.get_script_name()
	local json, err = utils.format_json({
		type = 'source-menu',
		title = 'Source: ' .. source_of(),
		items = items,
		-- uosc's callback menu mode (menus.lua): the table is spliced into
		-- "script-message-to <...callback...> <event json>", so this flat
		-- array is "<script> <message>" - every menu event (activate, keys,
		-- etc.) arrives at our 'menu-callback' instead of uosc trying to run
		-- item values as mpv commands.
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

-- ---- menu actions -----------------------------------------------------------------

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
		utils.subprocess_detached(args)
	else
		mp.set_property_native('user-data/source-info/launched', args)
	end
end

--- Opens a web address in the default browser: a plain http(s) URL only - no
--- whitespace, control characters, quotes, < > ^ ` { | } or backslash, which
--- no address a browser hands out contains raw (it percent-encodes them).
--- Never through cmd (see the header).
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

local function handle_activate(value)
	local verb, payload = split_action(value)
	if verb == 'copy' then
		copy(payload)
	elseif verb == 'open' then
		mp.commandv('loadfile', payload, 'replace')
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

-- With `callback` set, uosc sends every menu event here as JSON (see
-- uosc/lib/menus.lua open_command_menu's callback path).
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

-- For the regression test: the links the menu would offer for <path>, published
-- as user-data/source-info/links-for. A stream needs a server to load; this
-- reaches the same functions without one.
mp.register_script_message('links-for', function(path)
	local saved = state
	state = { path = path }
	mp.set_property_native('user-data/source-info/links-for', { stream = stream_url(), page = page_url() })
	state = saved
end)

-- Open the menu also through the binding the button JSON commands reach:
-- script-binding does not carry menu_command's own payload, uosc runs
-- menu_command itself. (Both point here.)

-- ---- state per file ---------------------------------------------------------------

mp.register_event('file-loaded', function()
	state.path = mp.get_property('path')
	update_button()
end)

-- The ytdl hook rewrites stream-open-filename while the file loads; capture
-- both sides so the menu can offer the real media URL and the original one.
-- After it, then: ytdl_hook's on_load runs at priority 10, and lower runs
-- first (until 2026-10-02 this ran at 5, saw nothing rewritten yet, and the
-- Original URL entry never appeared).
-- Only a web address counts as what was opened. For a YouTube link (pasted into
-- mpv directly - FastStream sends no YouTube) yt-dlp's separate audio and video
-- formats arrive as an edl:// list, a playlist as memory:// - neither is an
-- address another player or the browser can open, and the menu offered the EDL,
-- thousands of characters of expiring googlevideo links, as the "Stream URL"
-- (until 2026-10-04). Then the pasted link is the Stream URL, and "Open in mpv"
-- runs yt-dlp on it again.
mp.add_hook('on_load', 11, function()
	local path = mp.get_property('path') or ''
	state.loading = path
	local opened = mp.get_property('stream-open-filename') or ''
	if path:find('://', 1, true) and opened ~= path and opened:find('^https?://') then
		state.opened = opened
		state.origin = path
	end
end)

-- A FastStream stream that does not open (a refused or expired link: 403,
-- 404, a token the site has replaced) left an empty mpv window with nothing
-- said. Say what happened and what helps.
---@param event {reason: string, file_error: string|nil}
local function announce_failure(event)
	local path = state.loading or ''
	local hash = path:find('#', 1, true)
	if event.reason ~= 'error' or not hash then
		return
	end
	local fragment = path:sub(hash)
	if not (fragment:find('fs-content=', 1, true) or fragment:find('fs-id=', 1, true)) then
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
