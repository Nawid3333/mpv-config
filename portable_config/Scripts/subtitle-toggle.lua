-- subtitle-toggle.lua - the smart "c" key: loads, selects, shows or hides subtitles

local msg = require('mp.msg')
local utils = require('mp.utils')

local SUB_EXTS = { srt = true, ass = true, ssa = true, sub = true, vtt = true, sup = true }

-- The first subtitle track, and whether any is selected: not the same question, as --subs-fallback=default
-- selects none when no track matches slang and none is flagged default.
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

local function subs_visible()
	return mp.get_property_bool('sub-visibility')
end

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

	-- an exact <videoname>.<ext> match first, then fuzzy; the first found wins
	-- join_path: for a bare file name split_path gives the dir "." with no separator.
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

	-- The file has subtitles but mpv selected none (scan_sub_tracks): select the first and show it.
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

-- key=nil: the key lives in input.conf's script-binding line.
mp.add_key_binding(nil, 'smart-toggle', smart_toggle)
