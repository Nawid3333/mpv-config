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
-- <temp>/faststream-mpv-hls-*/<n>.m3u8 or master.m3u8, beside target.txt, the stream as sent with its tags.
local PACKAGE_PREFIX = 'faststream-mpv-hls-'
local MAX_TARGET_BYTES = 600 * 1024
local package_targets = {}

---@param dir string
---@return string
local function comparable(dir)
	local forward = dir:gsub('\\', '/')
	return (forward:gsub('/+$', ''):lower())
end

---@param path string
---@return string|nil the stream as sent, for a playlist file of the helper's in the temp folder
local function package_target(path)
	if package_targets[path] ~= nil then
		return package_targets[path] or nil
	end
	local target = false
	local forward = path:gsub('\\', '/')
	local dir, name = forward:match('^(.*)/([^/]+)$')
	local parent, folder = (dir or ''):match('^(.*)/([^/]+)$')
	if
		parent
		and (name == 'master.m3u8' or name:match('^%d%d?%.m3u8$'))
		and folder:sub(1, #PACKAGE_PREFIX) == PACKAGE_PREFIX
	then
		local in_temp = false
		-- faststream_fragment-temp: the folder the regression tests write a package into.
		local temps =
			{ os.getenv('TEMP'), os.getenv('TMP'), os.getenv('TMPDIR'), '/tmp', mp.get_opt('faststream_fragment-temp') }
		for i = 1, 5 do
			in_temp = in_temp or (temps[i] ~= nil and comparable(temps[i]) == comparable(parent))
		end
		local file = in_temp and io.open(dir .. '/target.txt', 'rb')
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

---@param path string|nil
---@return string[]
function M.items(path)
	local items = {}
	if type(path) == 'string' and not path:find('#', 1, true) then
		path = package_target(path) or path
	end
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
