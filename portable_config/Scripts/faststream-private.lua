-- faststream-private.lua - removes a private window's temp files once mpv has moved on from the stream or
-- closes. FastStream's helper (29) writes them with names that say so: the playlists of a stream mpv cannot open
-- alone into faststream-mpv-hls-p-<6>, beside target.txt (the stream as sent, fs-private=1 among its tags), and
-- the page's subtitles into faststream-mpv-subs-p-<6>. Only those files go: the helper's own names in folders so
-- named; the empty folders go by the helper's age rules (doc/scripts.md).

local mp = require('mp')
local utils = require('mp.utils')
local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))

local PACKAGE_FOLDER = '^faststream%-mpv%-hls%-p%-%w%w%w%w%w%w$'
local SUBTITLE_FOLDER = '^faststream%-mpv%-subs%-p%-%w%w%w%w%w%w$'
-- queued-<pid>: the helper's mark on a queued stream's folder (queue/main.lua), which keeps it while that mpv runs
local PACKAGE_FILES = { '^master%.m3u8$', '^%d%d?%.m3u8$', '^target%.txt$', '^queued%-%d+$' }
local MARKER = '^queued%-%d+$'
local SUBTITLE_FILE = '^%d+[^/]*%.srt$'

---@param path string
---@return string|nil folder, string|nil name, string|nil the folder's own name
local function split(path)
	local dir, name = path:gsub('\\', '/'):match('^(.*)/([^/]+)$')
	return dir, name, dir and dir:match('([^/]+)$')
end

--- The private package folder a path plays from: its folder's name and its target's fs-private tag both say so.
---@param path string|nil
---@return string|nil
local function package_folder(path)
	if type(path) ~= 'string' or not fragment.target(path) or fragment.value(path, 'fs-private=') ~= '1' then
		return nil
	end
	local dir, _, own = split(path)
	return own and own:match(PACKAGE_FOLDER) and dir or nil
end

---@param file any
---@return boolean
local function private_subtitle(file)
	if type(file) ~= 'string' or file:find('^%a[%w+.-]*://') then
		return false
	end
	local _, name, own = split(file)
	return own ~= nil and name ~= nil and own:match(SUBTITLE_FOLDER) ~= nil and name:match(SUBTITLE_FILE) ~= nil
end

--- The private subtitle files the file loading or playing now was given (sub-files, as the helper hands them
--- over, also when the file then fails to open) or loaded since.
---@return table<string, boolean>
local function subtitle_files()
	local found = {}
	for _, file in ipairs(mp.get_property_native('sub-files') or {}) do
		if private_subtitle(file) then
			found[file] = true
		end
	end
	for _, track in ipairs(mp.get_property_native('track-list') or {}) do
		local file = track.external and track['external-filename']
		if private_subtitle(file) then
			found[file] = true
		end
	end
	return found
end

local folders, files = {}, {} -- what the files loaded so far left: [folder] / [file] = true
local waiting = {} -- [folder] = true: packages of playlist entries not loaded yet (a queued stream)
local passes = 0

local function remove_package(dir)
	for _, name in ipairs(utils.readdir(dir, 'files') or {}) do
		for _, pattern in ipairs(PACKAGE_FILES) do
			if name:match(pattern) then
				os.remove(dir .. '/' .. name)
				break
			end
		end
	end
end

--- Removes what the files loaded before left, except what the one playing now uses (a quality switch takes the
--- subtitle files along, and the same package loaded again is its own).
---@param keep_folder string|nil
---@param keep_files table<string, boolean>
local function remove_all_but(keep_folder, keep_files)
	for dir in pairs(folders) do
		if dir ~= keep_folder then
			remove_package(dir)
			folders[dir] = nil
		end
	end
	for file in pairs(files) do
		if not keep_files[file] then
			os.remove(file)
			files[file] = nil
			-- a queued stream's subtitle folder: its mark goes with its last file
			local dir = split(file)
			for _, name in ipairs(dir and utils.readdir(dir, 'files') or {}) do
				if name:match(MARKER) then
					os.remove(dir .. '/' .. name)
				end
			end
		end
	end
	passes = passes + 1
	mp.set_property_native('user-data/faststream-private/passes', passes) -- the tests wait on it
end

-- Each load in turn, also one that then fails; a property observer may report a path late or not at all.
mp.add_hook('on_load', 50, function()
	local dir = package_folder(mp.get_property('path'))
	if dir then
		folders[dir] = true
	end
	for file in pairs(subtitle_files()) do
		files[file] = true
	end
end)

mp.register_event('file-loaded', function()
	local keep_files = subtitle_files()
	remove_all_but(package_folder(mp.get_property('path')), keep_files)
	for file in pairs(keep_files) do
		files[file] = true
	end
end)

--- The private packages the playlist names now.
---@param list table[]|nil
---@return table<string, boolean>
local function listed_packages(list)
	local now = {}
	for _, entry in ipairs(list or {}) do
		local dir = package_folder(entry.filename)
		if dir then
			now[dir] = true
		end
	end
	return now
end

-- A queued stream's package waits in the playlist; one that leaves it without being loaded (removed from the queue)
-- goes. Not at once: a replace of what plays empties the playlist before queue/main.lua puts the queue back behind it.
-- One that is loaded is the others' business above.
local LEFT_SECONDS = 2
mp.observe_property('playlist', 'native', function(_, list)
	local now = listed_packages(list)
	for dir in pairs(waiting) do
		if not now[dir] and not folders[dir] then
			mp.add_timeout(LEFT_SECONDS, function()
				if not listed_packages(mp.get_property_native('playlist'))[dir] and not folders[dir] then
					remove_package(dir)
					waiting[dir] = nil
				end
			end)
		end
	end
	for dir in pairs(now) do
		waiting[dir] = true
	end
end)

-- Nothing plays any more (the playlist ended, mpv idles) or mpv closes: all of it goes. Asked again, as the
-- notification may come after the next load has started.
mp.observe_property('idle-active', 'bool', function(_, idle)
	if idle and mp.get_property_bool('idle-active') then
		remove_all_but(nil, {})
	end
end)
mp.register_event('shutdown', function()
	for dir in pairs(waiting) do
		folders[dir] = true
	end
	remove_all_but(nil, {})
end)
