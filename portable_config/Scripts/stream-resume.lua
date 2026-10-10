-- stream-resume.lua - resume FastStream videos where they were left off
--
-- Requested 2026-09-24: "I open a video from the browser, watch part of it,
-- close mpv (maybe by accident), open it again from the browser - it should
-- continue from there, with the option to start from the beginning."
--
-- Why not mpv's own watch-later (save-position-on-quit): it keys a file by its
-- path, and a FastStream path is the CDN stream URL, which on streaming sites
-- carries an expiring token - the same episode arrives under a new URL every
-- time, so watch-later would never find its entry. Instead the FastStream
-- native host appends `fs-id=<16 hex>` to the URL fragment (never sent to the
-- CDN): a sha256 prefix of the browser tab's page URL, i.e. the episode page,
-- which IS stable. Only files carrying that marker are touched - local files
-- keep starting at 0:00 (user's choice: FastStream only).
--
-- Behavior (user-confirmed):
--   - position saved every SAVE_INTERVAL seconds and when the file unloads, so
--     a crash or accidental close loses at most a few seconds
--   - on reopen: auto-resume (no question), with a note saying where and
--     that Home (mpv's own default "seek to beginning") starts over. The note
--     is a notify.lua banner top right for NOTE_SECONDS, like every other
--     message (2026-09-26: it was big centered text for 6 s, which the user
--     found too big and too long).
--   - an entry is dropped when the video is finished (inside the last 8 %,
--     at least 30 s and at most 3 min: an episode's end credits and preview;
--     2026-10-02, it was max(30 s, 5 %), and saved entries of 33-44 min
--     episodes sat 1.7-2.3 min before the end, i.e. in the credits) or when
--     it has not been watched for EXPIRY_SECONDS (7 days) - no permanent
--     memory. Watching again resets the 7 days.
--   - a start position the sender gave with the file (FastStream's player
--     button hands over where the browser's player was, as the per-file
--     option start) wins over the saved one; the position is still saved
--   - the saved duration must match the reopened stream's (within
--     DURATION_TOLERANCE), so a site that serves several episodes under one
--     page URL cannot resume episode 3 at episode 2's position
--   - progress is mpv-only; the FastStream browser player keeps its own
--
-- State: ~~state/stream-resume.json (= portable_config/ on this install, see
-- remember-speed.lua), gitignored, safe to delete at any time.

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')

local EXPIRY_SECONDS = 7 * 24 * 60 * 60
local SAVE_INTERVAL = 5
-- Positions below this are not worth resuming (and dropping them is what makes
-- "Home, then close" forget the entry instead of resuming at 0:03).
local MIN_POSITION = 15
local DURATION_TOLERANCE = 5
-- The resume banner: long enough to read its Home hint, then out of the way.
local NOTE_SECONDS = 4

local state_file = mp.command_native({ 'expand-path', '~~state/' }) .. '/stream-resume.json'

-- The file being played, or nil when it has no fs-id marker:
--   { id = string, resumed = entry|nil, ready = bool, last_saved = number|nil }
local current = nil

--- The resume key: the hex digits of the LAST whole "fs-id=" item of the URL
--- fragment (everything after the first '#', items separated by '&'). The
--- native host drops fs-* items a stream URL already carries and appends its
--- own last, so neither a query parameter ("?x=1&fs-id=...", read as the key
--- until 2026-10-02) nor anything else the stream URL brings can pass for it.
---@param path string|nil
---@return string|nil
local function resume_id(path)
	local hash = path and path:find('#', 1, true)
	if not path or not hash then
		return nil
	end
	local id
	for item in (path:sub(hash + 1) .. '&'):gmatch('([^&]*)&') do
		if item:sub(1, 6) == 'fs-id=' then
			id = item:sub(7):match('^(%x+)')
		end
	end
	return id
end

--- Read the saved entries, dropping expired and malformed ones. A missing or
--- corrupt file reads as empty; the next save moves a corrupt one aside and
--- writes a new one.
--- The second result is true when something was dropped, i.e. the file on
--- disk still holds entries that should be gone.
--- The third result is true when the file exists but could not be read: saving
--- over it would then erase every other entry, so a save keeps it beside first.
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

--- Write via a temp file, so a crash mid-write cannot leave a truncated file.
--- The temp file is this process's own: two mpv windows saving at once used
--- one name and could write into each other's. Failures are logged, never
--- fatal.
---@param entries table
local function save_entries(entries)
	local tmp = state_file .. '.' .. utils.getpid() .. '.tmp'
	local file, open_err = io.open(tmp, 'w')
	if not file then
		msg.error('cannot write ' .. tmp .. ': ' .. tostring(open_err))
		return
	end
	-- format_json turns an empty table into [], which parse_json reads back as
	-- an empty table all the same.
	file:write(utils.format_json(entries) or '{}')
	file:close()
	-- os.rename does not replace an existing file on Windows.
	os.remove(state_file)
	local ok, rename_err = os.rename(tmp, state_file)
	if not ok then
		msg.error('cannot replace ' .. state_file .. ': ' .. tostring(rename_err))
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

--- Record the current position (or drop the entry when finished / near the
--- start). Re-reads the file first, so two mpv windows do not erase each
--- other's entries.
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
		-- Not JSON: the file is written through a temp file and renamed, so another
		-- window's save is never seen half-written - it is damaged. It is kept beside
		-- (for a look) and saving goes on: skipped every time, it ended resuming for
		-- every stream for good.
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
	-- The sender asked for a position of its own (a per-file start option, "none"
	-- when unset): that one plays, and the saved one is only updated from here.
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

-- A banner top right (Scripts/notify.lua draws every message).
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
