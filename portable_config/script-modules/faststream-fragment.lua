-- faststream-fragment.lua - reads the FastStream helper's tags from the URL fragment (AGENTS.md,
-- "FastStream contract") and what a reopened stream takes along. Loaded with dofile().

local mp = require('mp')

local M = {}

---@return table<string, string> none when there is nothing to take along
function M.reopen_options()
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

-- An HLS stream mpv cannot open from its address plays from files FastStream's helper (27) wrote:
-- <temp>/faststream-mpv-hls-<6 random>/<n>.m3u8 or master.m3u8 (p-<6 random> for a private window's), beside
-- target.txt, the stream as sent with its tags. Known by the folder's name alone: the helper's temp folder and
-- mpv's need not be spelled alike (doc/scripts.md).
local PACKAGE_FOLDERS = { '^faststream%-mpv%-hls%-%w%w%w%w%w%w$', '^faststream%-mpv%-hls%-p%-%w%w%w%w%w%w$' }
local MAX_TARGET_BYTES = 600 * 1024
local package_targets = {}

---@param path string
---@return string|nil the stream as sent, for a playlist file of the helper's
local function package_target(path)
	if package_targets[path] ~= nil then
		return package_targets[path] or nil
	end
	local target = false
	local dir, name = path:gsub('\\', '/'):match('^(.*)/([^/]+)$')
	local folder = dir and dir:match('([^/]+)$')
	if
		folder
		and (name == 'master.m3u8' or name:match('^%d%d?%.m3u8$'))
		and (folder:match(PACKAGE_FOLDERS[1]) or folder:match(PACKAGE_FOLDERS[2]))
	then
		local file = io.open(dir .. '/target.txt', 'rb')
		if file then
			local text = file:read(MAX_TARGET_BYTES + 1) or ''
			file:close()
			if #text <= MAX_TARGET_BYTES and text:match('^https?://[^%c]+$') then
				target = text
			end
		end
	end
	package_targets[path] = target
	return target or nil
end

--- The stream as FastStream sent it, for a playlist file of its helper's (doc/scripts.md).
---@param path string|nil
---@return string|nil nil for an address and for any other file
function M.target(path)
	if type(path) ~= 'string' or path:find('^%a[%w+.-]*://') then
		return nil
	end
	return package_target(path)
end

-- Read as each file starts, by every script with this module: the helper removes a private window's folder once
-- mpv moved on from it, and a script may ask later (Auto upscale picked during playback).
if mp and mp.observe_property then
	mp.observe_property('path', 'string', function(_, path)
		M.target(path)
	end)
end

---@param path string|nil
---@return string[]
function M.items(path)
	local items = {}
	path = M.target(path) or path
	local hash = type(path) == 'string' and path:find('#', 1, true)
	if hash and path then
		for item in (path:sub(hash + 1) .. '&'):gmatch('([^&]*)&') do
			items[#items + 1] = item
		end
	end
	return items
end

---@param path string|nil
---@param marker string
---@return string|nil
function M.value(path, marker)
	local value
	for _, item in ipairs(M.items(path)) do
		if item:sub(1, #marker) == marker then
			value = item:sub(#marker + 1)
		end
	end
	return value
end

return M
