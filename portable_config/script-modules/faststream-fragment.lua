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

---@param path string|nil
---@return string[]
function M.items(path)
	local items = {}
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
