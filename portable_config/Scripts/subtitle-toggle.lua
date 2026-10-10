-- subtitle-toggle.lua
-- Smart "c" key:
--   1. no subtitles loaded -> OSD "No subtitles" + scan the video's folder
--      for subtitle files and load+select one if found (sub-add)
--   2. subs loaded but none SELECTED -> select the first one and show it
--   3. subs loaded but hidden -> show (OSD "Subtitles: on")
--   4. subs shown -> hide (OSD "Subtitles: off")
-- Falls back gracefully when uosc (phase 2) is present: after a failed
-- scan, uosc's file-picker binding remains available via the RMB menu.

local msg = require('mp.msg')
local utils = require('mp.utils')

local SUB_EXTS = { srt = true, ass = true, ssa = true, sub = true, vtt = true, sup = true }

-- One pass over track-list answering both questions the toggle needs:
-- the first subtitle track (nil if the file has none), and whether any
-- subtitle track is actually SELECTED right now.
--
-- Those are deliberately NOT the same question. mpv's --subs-fallback
-- defaults to `default`, so when no track matches mpv.conf's `slang=de,en`
-- and none is flagged default (a Japanese- or Spanish-only release, say),
-- mpv selects NO subtitle track at all. The old code only checked that a
-- sub track existed, so pressing c on such a file flipped sub-visibility,
-- printed "Subtitles: on" and showed nothing - the one case where the smart
-- key most needed to actually do something.
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

-- returns true if a subtitle track is currently displayed
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
	-- strip extension from the video filename for fuzzy matching
	local base = filename:match('^(.+)%.[^%.]+$') or filename
	local base_lower = base:lower()

	local entries = utils.readdir(dir)
	if not entries then
		return nil
	end

	-- prefer an exact <videoname>.<ext> match, then fuzzy, first found wins.
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

-- A banner top right (Scripts/notify.lua draws every message; the same id
-- replaces the last one).
local function notify(title, detail)
	mp.commandv('script-message-to', 'notify', 'show', 'subtitles', title, detail or '')
end

local function smart_toggle()
	local track, selected = scan_sub_tracks()

	if not track then
		-- try to auto-load from the video's folder before giving up
		local file = find_subtitle_file()
		if file then
			local _, loaded_name = utils.split_path(file)
			-- the command's own result (AGENTS.md validation item 3): a file mpv
			-- cannot open or parse must not be announced as loaded
			local ok, err = mp.commandv('sub-add', file, 'select')
			if not ok then
				notify('No subtitles', 'could not load ' .. loaded_name)
				msg.warn('sub-add ' .. file .. ' failed: ' .. tostring(err))
				return
			end
			-- shown too: sub-visibility is mpv's own and stays off for the next files after
			-- c hid subtitles on one, and the banner said "Subtitles on" over nothing
			mp.set_property_bool('sub-visibility', true)
			notify('Subtitles on', 'loaded ' .. loaded_name)
			msg.info('auto-loaded subtitle: ' .. file)
			return
		end
		notify('No subtitles', 'none in the file or next to it')
		return
	end

	-- The file has subtitles but mpv picked none (see has_selected_sub) -
	-- select the first one and make sure it is actually visible, rather than
	-- toggling a visibility flag that has nothing to show.
	if not selected then
		mp.set_property_number('sid', track.id)
		mp.set_property_bool('sub-visibility', true)
		local label = track.lang or track.title or ('track ' .. tostring(track.id))
		notify('Subtitles on', label)
		msg.info('no sub track was selected; selected sid=' .. tostring(track.id))
		return
	end

	-- a track is selected: toggle visibility
	if subs_visible() then
		mp.set_property_bool('sub-visibility', false)
		notify('Subtitles off')
	else
		mp.set_property_bool('sub-visibility', true)
		notify('Subtitles on')
	end
end

-- key=nil: actual key ('c') lives in input.conf's script-binding line, same
-- convention as gpu-toggles.lua/speed-button.lua, so deleting that line
-- frees 'c' back to mpv's default instead of leaving it hardcoded here too.
mp.add_key_binding(nil, 'smart-toggle', smart_toggle)
