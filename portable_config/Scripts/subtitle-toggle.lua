-- subtitle-toggle.lua
-- Smart "c" key:
--   1. no subtitles loaded -> OSD "No subtitles" + scan the video's folder
--      for subtitle files and load+select one if found (sub-add)
--   2. subs loaded but none selected -> select the first one and show it
--   3. subs loaded but hidden -> show (OSD "Subtitles: on")
--   4. subs shown -> hide (OSD "Subtitles: off")
-- With uosc present, a failed scan still leaves uosc's file-picker binding
-- reachable via the RMB menu.

local msg = require('mp.msg')
local utils = require('mp.utils')

local SUB_EXTS = { srt = true, ass = true, ssa = true, sub = true, vtt = true, sup = true }

-- One pass over track-list answering both questions the toggle needs:
-- the first subtitle track (nil if the file has none) and whether any
-- subtitle track is selected right now.
--
-- These are deliberately NOT the same question: mpv's --subs-fallback
-- defaults to `default`, so when no track matches mpv.conf's `slang=de,en`
-- and none is flagged default (a Japanese- or Spanish-only release, say),
-- mpv selects NO subtitle track at all despite the file having subs.
---@return table|nil first_sub, boolean any_selected
local function scan_sub_tracks()
	local track_list = mp.get_property_native('track-list', {})
	local first = nil
	for _, track in ipairs(track_list) do
		if track.type == 'sub' then
			if not first then
				first = track
			end
			if track.selected then
				return first, true
			end
		end
	end
	return first, false
end

-- true if a subtitle track is currently displayed
local function subs_visible()
	return mp.get_property_bool('sub-visibility')
end

-- scan the directory of the currently playing file for a subtitle file
-- whose name contains the video filename (fuzzy, same rule as sub-auto)
local function find_subtitle_file()
	local path = mp.get_property('path')
	if not path or path:find('://') then
		return nil -- streams have no folder to scan
	end

	local dir, filename = utils.split_path(path)
	local base = filename:match('^(.+)%.[^%.]+$') or filename
	local base_lower = base:lower()

	local entries = utils.readdir(dir)
	if not entries then
		return nil
	end

	-- prefer an exact <videoname>.<ext> match, then fuzzy; first found wins.
	-- join_path, not dir .. entry: for a bare file name (mpv started from a
	-- terminal with "mpv clip.mkv") split_path gives the dir "." with no
	-- separator, and "." .. "clip.srt" named a file that does not exist.
	local exact, fuzzy
	for _, entry in ipairs(entries) do
		local name, ext = entry:match('^(.+)%.(%w+)$')
		if name and ext and SUB_EXTS[ext:lower()] then
			local name_lower = name:lower()
			if name_lower == base_lower and not exact then
				exact = utils.join_path(dir, entry)
			elseif name_lower:find(base_lower, 1, true) and not fuzzy then
				fuzzy = utils.join_path(dir, entry)
			end
		end
	end
	return exact or fuzzy
end

-- Banner top right (Scripts/notify.lua draws every message; the same id
-- replaces the previous one).
local function notify(title, detail)
	mp.commandv('script-message-to', 'notify', 'show', 'subtitles', title, detail or '')
end

local function smart_toggle()
	local track, selected = scan_sub_tracks()

	if not track then
		local file = find_subtitle_file()
		if file then
			local _, loaded_name = utils.split_path(file)
			-- trust the command's own result: a file mpv cannot open or parse
			-- must not be announced as loaded
			local ok, err = mp.commandv('sub-add', file, 'select')
			if not ok then
				notify('No subtitles', 'could not load ' .. loaded_name)
				msg.warn('sub-add ' .. file .. ' failed: ' .. tostring(err))
				return
			end
			-- set sub-visibility too: it persists across files, so after 'c'
			-- hid subtitles on an earlier file the new track would load invisible
			mp.set_property_bool('sub-visibility', true)
			notify('Subtitles on', 'loaded ' .. loaded_name)
			msg.info('auto-loaded subtitle: ' .. file)
			return
		end
		notify('No subtitles', 'none in the file or next to it')
		return
	end

	-- The file has subtitles but mpv selected none (see scan_sub_tracks) -
	-- select the first one and make it visible, rather than toggling a
	-- visibility flag with nothing to show.
	if not selected then
		mp.set_property_number('sid', track.id)
		mp.set_property_bool('sub-visibility', true)
		local label = track.lang or track.title or ('track ' .. tostring(track.id))
		notify('Subtitles on', label)
		msg.info('no sub track was selected; selected sid=' .. tostring(track.id))
		return
	end

	if subs_visible() then
		mp.set_property_bool('sub-visibility', false)
		notify('Subtitles off')
	else
		mp.set_property_bool('sub-visibility', true)
		notify('Subtitles on')
	end
end

-- key=nil: the actual key ('c') lives in input.conf's script-binding line,
-- same convention as gpu-toggles.lua/speed-button.lua; deleting that line
-- frees 'c' back to mpv's default instead of leaving it hardcoded here too.
mp.add_key_binding(nil, 'smart-toggle', smart_toggle)
