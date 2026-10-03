-- remember-speed.lua - persist the last playback speed across mpv runs and files
--
-- mpv's own `speed` option already carries across files WITHIN one mpv
-- process (it is a global option, not file-local - see the mpv manual's
-- "Per-File Options": only file-local options reset between files). What
-- does NOT carry is the value across a fresh `mpv.exe` launch: there it
-- resets to 1x every time. The watch-later mechanism is per-file (hashed
-- from the file's path), so it restores the speed OF that file - not "the
-- last speed I picked, for whatever I play next", which is what is wanted
-- here (and watch-later only writes on explicit quit-with-save / file end
-- anyway, not on every speed change).
--
-- So: save `speed` to a small JSON file on every change, load it once at
-- startup, and re-apply it. The file lives in ~~state/ (resolved live via
-- expand-path, since that prefix maps to portable_config/ on this portable
-- install - verified, not assumed; a hardcoded path would break if the repo
-- moved).
--
-- VIDEO ONLY (2026-09-19): both the SAVE and the RESTORE are scoped to files
-- with a real video track - audio files (music) neither save nor restore the
-- speed, so a speed picked on an anime is never clobbered by one chosen for an
-- album, and opening mpv on music does not run it at 3x. "Real video"
-- excludes album art: an embedded cover makes an audio file technically have a
-- "video" track (track-list/N/albumart, manual), so the file counts as video
-- only if it has a video track that is neither albumart nor a single-image
-- track (track-list/N/image) - the same classification uosc itself uses
-- (main.lua's track-list observer). Before track-list arrives (fresh process,
-- first file loading), nothing is saved: track-list is the first per-file fact
-- available, so a speed change during the load window is simply not persisted
-- - the next save (any later change, on any video) covers it. mpv's own
-- audio-only speed behavior (scaletempo2) is not affected - only this memory
-- is scoped.
--
-- WITHIN ONE PROCESS too (2026-10-02): `speed` is a global option, so a song
-- after a 3x episode played at 3x (FastStream's next episode, a playlist, a
-- drop into the open window - all one process). A switch between a video and
-- an audio file now sets the speed of that kind: a song plays at the speed last
-- chosen on a song (1x until then), and the next video gets the video speed
-- back. Only on a switch: two videos in a row keep whatever speed is set.

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')

local state_file = mp.command_native({ 'expand-path', '~~state/' }) .. '/speed.json'

--- True if the current file has a real video track (not album art, not a
--- single-image track). nil while track-list is not (yet) populated.
---@return boolean|nil
local function is_video_file()
	local tracks = mp.get_property_native('track-list')
	if tracks == nil then
		return nil
	end
	for _, track in ipairs(tracks) do
		if track.type == 'video' and not track.image and not track.albumart then
			return true
		end
	end
	return false
end

--- Read the saved speed, or nil if the file is missing/corrupt/unreadable.
--- A corrupt file is NOT deleted here - the next successful save overwrites it.
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

--- Write the current speed to the state file, through a temp file of this
--- process's own: written in place, a crash between emptying the file and
--- writing it left it empty, and the saved speed was gone. All failures are
--- logged, not fatal: a broken save must never stop playback.
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

-- RESTORE: at the first file-loaded that turns out to be a video file, apply
-- the saved speed. Restoring here (instead of unconditionally at script load,
-- as this script first did) is what makes the audio/video scoping possible:
-- the file type is only knowable from track-list, which arrives per file, and
-- mpv can be launched straight into an audio file (double-clicked album) -
-- restoring the video speed onto that would be exactly what this scoping is
-- meant to prevent. observe_property('speed') is guaranteed to fire on the set
-- below (its initial read happens at script load, before any file-loaded), so
-- the restored value is re-saved immediately, self-healing.
local restored = false
-- The speed of each kind of file in this process, and the kind of the file
-- before (nil until one has loaded): see "WITHIN ONE PROCESS" above.
local video_speed = nil
local audio_speed = 1
local last_kind = nil

---@param speed number
local function set_speed(speed)
	if math.abs(mp.get_property_native('speed', 1) - speed) > 0.0001 then
		mp.set_property_native('speed', speed)
	end
end

mp.register_event('file-loaded', function()
	local video = is_video_file()
	if video == nil then
		return
	end
	local kind = video and 'video' or 'audio'
	if not restored and video then
		local saved = load_speed()
		if saved and saved > 0 then
			set_speed(saved)
		end
		restored = true
	elseif last_kind and kind ~= last_kind then
		if kind == 'audio' then
			set_speed(audio_speed)
		elseif video_speed then
			set_speed(video_speed)
		end
	end
	last_kind = kind
end)

-- SAVE: on every change - but only while a video file is loaded. Audio files
-- never write the state file (their speed choice stays session-local).
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
