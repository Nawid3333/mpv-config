-- faststream-fragment.lua - how the scripts read the FastStream helper's tags (AGENTS.md,
-- "FastStream contract"): items in the URL fragment - everything after the FIRST '#',
-- items separated by '&' - each a whole "fs-<name>=<value>" item, the LAST one of a
-- name counting. A site's own query ("?x=fs-content=anime") or a fragment item that
-- only ends in a tag ("#xfs-id=...") is no tag. Plain string compares throughout: a "%"
-- in an address never starts a Lua pattern class.
--
-- Loaded with dofile() (see state-file.lua for why not from Scripts/):
--
--   local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))
--
-- It was six copies of the same loop (faststream-episodes, faststream-quality,
-- gpu-toggles, source-info, stream-resume, video-info), each to be changed alike
-- (issue #96); the static tier now checks no script parses the fragment by itself.
--
-- Also here: reopen_options(), what a file opened again (a quality switch, "Open"
-- in the source menu) takes along, once copied in faststream-quality and source-info.

local mp = require('mp')

local M = {}

--- The per-file options a stream needs when it is opened again: the request headers
--- and the title the FastStream helper gave it. Header fields as one comma list with
--- each field's own commas escaped (mpv's list syntax); a field ending in a backslash
--- cannot be written so and is left out, as the helper leaves it out.
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

--- The fragment's items, in order; none without a '#'.
---@param path string|nil
---@return string[]
function M.items(path)
	local items = {}
	local hash = type(path) == 'string' and path:find('#', 1, true)
	if hash then
		for item in (path:sub(hash + 1) .. '&'):gmatch('([^&]*)&') do
			items[#items + 1] = item
		end
	end
	return items
end

--- The value of the last whole item that starts with the marker ("fs-id="), as it is
--- written (not decoded): '' for an empty one, nil without one.
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
