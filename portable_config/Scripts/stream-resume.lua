-- stream-resume.lua - resume FastStream videos where they were left off.

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')
local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))

local EXPIRY_SECONDS = 7 * 24 * 60 * 60
local SAVE_INTERVAL = 5
-- Positions below this are not worth resuming (and dropping them is what makes
-- "Home, then close" forget the entry instead of resuming at 0:03).
local MIN_POSITION = 15
local DURATION_TOLERANCE = 5
-- The resume banner: long enough to read its Home hint, then out of the way.
local NOTE_SECONDS = 4

local state_file = mp.command_native({ 'expand-path', '~~state/' }) .. '/stream-resume.json'
local statefile = dofile(mp.command_native({ 'expand-path', '~~/script-modules/state-file.lua' }))

-- The file being played, or nil when it has no fs-id marker:
--   { id = string, resumed = entry|nil, ready = bool, last_saved = number|nil }
local current = nil

--- The resume key: the hex digits of the last whole "fs-id=" fragment item (the helper appends its own last).
--- None for a private window's stream (fs-private=1): nothing read or saved; its fs-id stays for faststream-episodes.
---@param path string|nil
---@return string|nil
local function resume_id(path)
	if fragment.value(path, 'fs-private=') == '1' then
		return nil
	end
	local id = fragment.value(path, 'fs-id=')
	return id and id:match('^(%x+)')
end

--- The saved entries, expired and malformed ones dropped; a missing or damaged file reads as empty.
--- Second result: something was dropped. Third: the file is there but unreadable, so a save keeps it beside first.
---@param path string|nil the state file (default) or a copy of it
---@return table<string, {pos: number, duration: number, updated: number}>, boolean, boolean
local function load_entries(path)
	local file = io.open(path or state_file, 'r')
	if not file then
		return {}, false, false
	end
	local content = file:read('*a')
	file:close()
	local data = utils.parse_json(content)
	if type(data) ~= 'table' then
		return {}, false, content ~= ''
	end
	local pruned = false
	local cutoff = os.time() - EXPIRY_SECONDS
	local entries = {}
	for id, entry in pairs(data) do
		if
			type(entry) == 'table'
			and type(entry.pos) == 'number'
			and type(entry.duration) == 'number'
			and type(entry.updated) == 'number'
			and entry.updated >= cutoff
		then
			entries[id] = entry
		else
			pruned = true
		end
	end
	return entries, pruned, false
end

---@param entries table
local function save_entries(entries)
	-- format_json turns an empty table into [], which parse_json reads back as
	-- an empty table all the same.
	local ok, err = statefile.write(state_file, utils.format_json(entries) or '{}')
	if not ok then
		msg.error(err)
	end
end

---@param pos number
---@param duration number
---@return boolean
local function is_finished(pos, duration)
	return pos >= duration - math.max(30, math.min(180, duration * 0.08))
end

---@param seconds number
---@return string
local function format_time(seconds)
	local s = math.floor(seconds)
	local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
	if h > 0 then
		return string.format('%d:%02d:%02d', h, m, s % 60)
	end
	return string.format('%d:%02d', m, s % 60)
end

--- Records the position, or drops the entry; re-reads the file first, so two mpv windows keep each other's entries.
local function save_position()
	if not current or not current.ready then
		return
	end
	local pos = mp.get_property_number('time-pos')
	local duration = mp.get_property_number('duration')
	-- No duration = live stream, nothing to resume.
	if not pos or not duration or duration <= 0 then
		return
	end
	local keep = pos >= MIN_POSITION and not is_finished(pos, duration)
	if keep and current.last_saved and math.abs(pos - current.last_saved) < 1 then
		return
	end
	local entries, _, unreadable = load_entries()
	if unreadable then
		-- Unreadable means damaged (saves are whole or nothing): kept beside, and saving goes on.
		local aside = state_file .. '.corrupt-' .. os.date('%Y%m%d-%H%M%S')
		if not os.rename(state_file, aside) then
			msg.warn('stream-resume.json could not be read or moved aside; not saving over it')
			return
		end
		-- What was moved is read again: another mpv window may have saved a good file
		-- over the damaged one since, and its entries stay.
		local damaged
		entries, _, damaged = load_entries(aside)
		if damaged then
			msg.warn('stream-resume.json could not be read: kept as ' .. aside .. ', saving anew')
		else
			os.remove(aside)
		end
	end
	if keep then
		entries[current.id] = { pos = pos, duration = duration, updated = os.time() }
		current.last_saved = pos
	elseif entries[current.id] then
		entries[current.id] = nil
		current.last_saved = nil
	else
		return
	end
	save_entries(entries)
end

-- Before the stream opens: set the start position, so mpv fetches from the
-- saved point directly instead of loading 0:00 and seeking.
mp.add_hook('on_load', 50, function()
	current = nil
	local id = resume_id(mp.get_property('path'))
	if not id then
		return
	end
	current = { id = id }
	-- A start position given with the file (per-file start option, "none" when
	-- unset) wins over the saved one; the saved one is still updated from here.
	local start = mp.get_property('file-local-options/start')
	if start and start ~= 'none' and start ~= '' then
		msg.info('start ' .. start .. ' given with the file; not resuming')
		return
	end
	local entry = load_entries()[id]
	if entry and entry.pos >= MIN_POSITION then
		current.resumed = entry
		mp.set_property('file-local-options/start', tostring(entry.pos))
	end
end)

mp.register_event('file-loaded', function()
	if not current then
		return
	end
	local entry = current.resumed
	if entry then
		local duration = mp.get_property_number('duration')
		if not duration or math.abs(duration - entry.duration) > DURATION_TOLERANCE then
			-- A different video under the same page URL: start it from the top.
			msg.info('saved duration does not match, not resuming')
			current.resumed = nil
			mp.commandv('seek', '0', 'absolute')
		end
	end
	current.ready = true
end)

---@param pos number
local function show_note(pos)
	mp.commandv(
		'script-message-to',
		'notify',
		'show',
		'resume',
		'Resumed at ' .. format_time(pos),
		'Home: start from the beginning',
		tostring(NOTE_SECONDS)
	)
end

-- Announce once the resume seek has actually landed.
mp.register_event('playback-restart', function()
	if current and current.resumed and not current.announced then
		current.announced = true
		show_note(current.resumed.pos)
	end
end)

mp.add_hook('on_unload', 50, function()
	save_position()
	-- The note belongs to this file: gone as soon as the next one loads.
	if current and current.announced then
		mp.commandv('script-message-to', 'notify', 'hide', 'resume')
	end
	current = nil
end)

-- Expired entries are otherwise only dropped from the file by the next save,
-- which never comes if FastStream is not used for a while.
do
	local entries, pruned = load_entries()
	if pruned then
		save_entries(entries)
	end
end

mp.add_periodic_timer(SAVE_INTERVAL, save_position)
