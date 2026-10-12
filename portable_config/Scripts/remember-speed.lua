-- remember-speed.lua - persist the last playback speed across mpv runs and files
--
-- `speed` is a global option: it carries across files within one process but
-- starts at 1x in a fresh one. Watch-later is no substitute - it is per file
-- (the speed OF that file, not the last speed picked) and writes only on
-- quit-with-save. So every change is saved to ~~state/speed.json and restored
-- at the first video of a process.
--
-- VIDEO ONLY: songs neither save nor restore it, so a speed picked for an
-- album never replaces the one for videos. A file counts as video only with a
-- video track that is neither album art nor a single image (the
-- classification uosc uses); track-list is empty while a file loads, so the
-- kind is known from file-loaded on.
--
-- WITHIN ONE PROCESS a switch between a video and a song sets that kind's
-- speed (a song after a 3x episode would otherwise play at 3x); two files of
-- the same kind keep whatever speed is set.
--
-- A speed picked WHILE A FILE LOADS (FastStream streams take seconds) is the
-- user's choice for that file: it wins over the restore and the kind switch.
-- A speed the file brings along (watch-later's saved one, a per-file option) is
-- not a pick: mpv applies it before the on_load hooks, where the snapshot is taken.

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')

local state_file = mp.command_native({ 'expand-path', '~~state/' }) .. '/speed.json'

--- True if the current file has a real video track (not album art, not a
--- single-image track). nil while track-list is empty: at script load and
--- between two files.
---@return boolean|nil
local function is_video_file()
	local tracks = mp.get_property_native('track-list')
	if tracks == nil or #tracks == 0 then
		return nil
	end
	for _, track in ipairs(tracks) do
		if track.type == 'video' and not track.image and not track.albumart then
			return true
		end
	end
	return false
end

--- The saved speed, or nil if the file is missing or corrupt (a corrupt file
--- is overwritten by the next save).
---@return number|nil
local function load_speed()
	local file = io.open(state_file, 'r')
	if not file then
		return nil
	end
	local content = file:read('*a')
	file:close()
	local data = utils.parse_json(content)
	if type(data) == 'table' and type(data.speed) == 'number' then
		return data.speed
	end
	return nil
end

--- Writes the speed through a temp file of this process, so a crash never
--- leaves an empty file. Failures are logged, never fatal.
---@param speed number
local function save_speed(speed)
	local json = utils.format_json({ speed = speed })
	if not json then
		msg.error('cannot serialize speed ' .. tostring(speed))
		return
	end
	local tmp = state_file .. '.' .. utils.getpid() .. '.tmp'
	local file, open_err = io.open(tmp, 'w')
	if not file then
		msg.error('cannot write ' .. tmp .. ': ' .. tostring(open_err))
		return
	end
	file:write(json)
	file:close()
	-- os.rename does not replace an existing file on Windows.
	os.remove(state_file)
	local ok, rename_err = os.rename(tmp, state_file)
	if not ok then
		msg.error('cannot replace ' .. state_file .. ': ' .. tostring(rename_err))
	end
end

local restored = false -- the saved speed is applied once per process
local video_speed = nil -- each kind's speed in this process
local audio_speed = 1
local last_kind = nil -- the kind of the file before, nil until one loaded
-- the speed at the loading file's on_load: a different one at its file-loaded
-- was picked while it loaded
local speed_at_load_start = mp.get_property_native('speed', 1)
local speed_at_start = nil -- the speed the current file started playing with

local function differs(a, b)
	return math.abs(a - b) > 0.0001
end

---@param speed number
local function set_speed(speed)
	if differs(mp.get_property_native('speed', 1), speed) then
		mp.set_property_native('speed', speed)
	end
end

mp.register_event('file-loaded', function()
	local video = is_video_file()
	if video == nil then
		speed_at_start = mp.get_property_native('speed', 1)
		return
	end
	local kind = video and 'video' or 'audio'
	local speed = mp.get_property_native('speed', 1)
	if differs(speed, speed_at_load_start) then
		if video then
			video_speed = speed
			save_speed(speed)
		else
			audio_speed = speed
		end
		restored = restored or video
	elseif not restored and video then
		-- Here and not at script load: only track-list tells whether mpv was
		-- started on a video or on an album. The observer re-saves the value.
		local saved = load_speed()
		if saved and saved > 0 then
			set_speed(saved)
		elseif last_kind == 'audio' then
			set_speed(1) -- nothing saved yet: a song's speed is not the video speed
		end
		restored = true
		-- known from now on, also when nothing changes it (the observer learns
		-- it only from a change)
		video_speed = mp.get_property_native('speed', 1)
	elseif last_kind and kind ~= last_kind then
		if kind == 'audio' then
			set_speed(audio_speed)
		elseif video_speed then
			set_speed(video_speed)
		end
	elseif kind == 'audio' then
		audio_speed = speed -- a first song
	end
	last_kind = kind
	speed_at_start = mp.get_property_native('speed', 1)
end)

-- SAVE on every change while a video is loaded; a song's speed stays in this
-- process.
mp.observe_property('speed', 'native', function(_, speed)
	if type(speed) ~= 'number' or speed <= 0 then
		return
	end
	local video = is_video_file()
	if video then
		video_speed = speed
		save_speed(speed)
	elseif video == false then
		audio_speed = speed
	end
end)

-- The speed a file has when it goes is its kind's: the observer may hear of a
-- change only after the next file has replaced this one (a speed set on a song
-- right before a video loads would then count as the video's). Only a speed
-- changed while the file played: one it brought along is not saved.
mp.add_hook('on_unload', 50, function()
	local speed = mp.get_property_native('speed')
	if type(speed) ~= 'number' or speed <= 0 or (speed_at_start and not differs(speed, speed_at_start)) then
		return
	end
	if last_kind == 'audio' then
		audio_speed = speed
	elseif last_kind == 'video' and (not video_speed or differs(speed, video_speed)) then
		video_speed = speed
		save_speed(speed)
	end
end)

-- Before every other on_load hook, after mpv has applied the file's own options.
mp.add_hook('on_load', 5, function()
	speed_at_load_start = mp.get_property_native('speed', 1)
end)
