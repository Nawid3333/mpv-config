-- remember-speed.lua - persist the last playback speed across mpv runs and files

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')

local state_file = mp.command_native({ 'expand-path', '~~state/' }) .. '/speed.json'
local statefile = dofile(mp.command_native({ 'expand-path', '~~/script-modules/state-file.lua' }))

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

---@param speed number
local function save_speed(speed)
	local json = utils.format_json({ speed = speed })
	if not json then
		msg.error('cannot serialize speed ' .. tostring(speed))
		return
	end
	local ok, err = statefile.write(state_file, json)
	if not ok then
		msg.error(err)
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
		-- Here, not at script load: only track-list tells a video from an album.
		local saved = load_speed()
		if saved and saved > 0 then
			set_speed(saved)
		elseif last_kind == 'audio' then
			set_speed(1) -- nothing saved yet: a song's speed is not the video speed
		end
		restored = true
		-- known from now on: the observer learns it only from a change
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

-- Saved on every change while a video is loaded; a song's speed stays in this process.
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

-- A file's speed at unload is its kind's: the observer may hear of a change only after the next file loaded.
-- Only a speed changed while it played is saved, not one the file brought along.
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
