-- state-file.lua - replaces a state file whole or not at all, and reads one (a damaged one is moved aside).
-- Loaded with dofile(), not a player script: mpv runs every .lua and every folder in scripts/.

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')

local M = {}

-- MoveFileExW through the FFI, or nil.
local move_file = nil
local ffi_ok, ffi = pcall(require, 'ffi')
if ffi_ok and ffi.os == 'Windows' then
	pcall(function()
		ffi.cdef([[
			int MultiByteToWideChar(unsigned int page, unsigned long flags, const char *text, int bytes,
				wchar_t *wide, int chars);
			int MoveFileExW(const wchar_t *from, const wchar_t *to, unsigned long flags);
		]])
		local kernel32 = ffi.load('kernel32')
		local CP_UTF8, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH = 65001, 1, 8
		local function wide(text)
			local chars = kernel32.MultiByteToWideChar(CP_UTF8, 0, text, -1, nil, 0)
			if chars <= 0 then
				return nil
			end
			local buffer = ffi.new('wchar_t[?]', chars)
			if kernel32.MultiByteToWideChar(CP_UTF8, 0, text, -1, buffer, chars) <= 0 then
				return nil
			end
			return buffer
		end
		move_file = function(from, to)
			local wide_from, wide_to = wide(from), wide(to)
			return wide_from ~= nil
				and wide_to ~= nil
				and kernel32.MoveFileExW(wide_from, wide_to, MOVEFILE_REPLACE_EXISTING + MOVEFILE_WRITE_THROUGH)
					~= 0
		end
	end)
end

---@param path string
---@param text string
---@return boolean ok
---@return string|nil err
function M.write(path, text)
	local tmp = path .. '.' .. utils.getpid() .. '.tmp'
	local file, open_err = io.open(tmp, 'wb')
	if not file then
		return false, 'cannot write ' .. tmp .. ': ' .. tostring(open_err)
	end
	local written, write_err = file:write(text)
	local closed, close_err = file:close()
	local info = written and closed and utils.file_info(tmp)
	if not (info and info.size == #text) then
		os.remove(tmp)
		return false, 'cannot write ' .. tmp .. ': ' .. tostring(write_err or close_err or 'short file')
	end
	if move_file and move_file(tmp, path) then
		return true
	end
	if os.rename(tmp, path) then
		return true
	end
	-- Windows without the FFI: rename cannot replace, so the old file goes first.
	os.remove(path)
	local renamed, rename_err = os.rename(tmp, path)
	if not renamed then
		os.remove(tmp)
		return false, 'cannot replace ' .. path .. ': ' .. tostring(rename_err)
	end
	return true
end

---@param path string
---@param name string what the warning calls the file
---@return table|nil data
---@return boolean|nil stuck a damaged file that could not be moved aside
function M.read_json(path, name)
	local file = io.open(path, 'rb')
	if not file then
		return nil
	end
	local text = file:read('*a')
	file:close()
	local data = utils.parse_json(text or '')
	if type(data) == 'table' then
		return data
	end
	local aside = path .. '.corrupt-' .. os.date('%Y%m%d-%H%M%S')
	if os.rename(path, aside) then
		msg.warn(name .. ' could not be read: kept as ' .. aside .. ', starting from the defaults')
		return nil
	end
	msg.warn(name .. ' could not be read or moved aside: not saving over it')
	return nil, true
end

--- A copy of plain data (tables of strings, numbers and booleans).
function M.copy(value)
	if type(value) ~= 'table' then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = M.copy(v)
	end
	return out
end

local function same(a, b)
	if type(a) ~= 'table' or type(b) ~= 'table' then
		return a == b
	end
	for k, v in pairs(a) do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

--- Saves `now` as JSON over what the file holds at this moment, writing only what differs from `base` (what this
--- process read or last wrote), one level down in tables (each screen, each measured cost). Several mpv windows share
--- a state file and each reads it at its start: an older window's whole copy written back undid what another window
--- had saved since. Without a base, or without a readable file, `now` is written whole; a damaged file that cannot be
--- moved aside is not saved over.
---@param path string
---@param now table
---@param base table|nil
---@param name string what a warning calls the file
---@return boolean ok
---@return string|nil err
function M.write_changes(path, now, base, name)
	local out = now
	if base then
		local file, stuck = M.read_json(path, name)
		if stuck then
			return false, name .. ' could not be read: not saving over it'
		end
		if file then
			-- plain tables: mpv's JSON reader marks a table read from [] as an array, and string keys put into it
			-- were dropped when it was written again (an empty "screens" took no screen)
			out = M.copy(file)
			for key, value in pairs(now) do
				local old = base[key]
				if type(value) == 'table' and type(old) == 'table' then
					local into = type(out[key]) == 'table' and out[key] or {}
					for sub in pairs(old) do
						if value[sub] == nil then
							into[sub] = nil
						end
					end
					for sub, v in pairs(value) do
						if not same(v, old[sub]) then
							into[sub] = M.copy(v)
						end
					end
					out[key] = into
				elseif not same(value, old) then
					out[key] = M.copy(value)
				end
			end
			for key in pairs(base) do
				if now[key] == nil then
					out[key] = nil
				end
			end
		end
	end
	local json = utils.format_json(out)
	if not json then
		return false, 'cannot serialize ' .. name
	end
	return M.write(path, json)
end

return M
